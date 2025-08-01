// SPDX-FileCopyrightText: 2024 SAP SE or an SAP affiliate company and Gardener contributors
//
// SPDX-License-Identifier: Apache-2.0

package app

import (
	"context"
	"fmt"

	dnsapi "github.com/gardener/external-dns-management/pkg/apis/dns/v1alpha1"
	extensionscontroller "github.com/gardener/gardener/extensions/pkg/controller"
	"github.com/gardener/gardener/extensions/pkg/controller/heartbeat"
	"github.com/gardener/gardener/extensions/pkg/util"
	"github.com/spf13/cobra"
	corev1 "k8s.io/api/core/v1"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/scheme"
	componentbaseconfigv1alpha1 "k8s.io/component-base/config/v1alpha1"
	"k8s.io/component-base/version/verflag"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"
	"sigs.k8s.io/controller-runtime/pkg/manager"

	serviceinstall "github.com/gardener/gardener-extension-shoot-dns-service/pkg/apis/service/install"
	"github.com/gardener/gardener-extension-shoot-dns-service/pkg/controller/config"
	"github.com/gardener/gardener-extension-shoot-dns-service/pkg/controller/healthcheck"
	"github.com/gardener/gardener-extension-shoot-dns-service/pkg/controller/lifecycle"
	"github.com/gardener/gardener-extension-shoot-dns-service/pkg/service"
)

// NewServiceControllerCommand creates a new command used to start the DNS Service controller.
func NewServiceControllerCommand() *cobra.Command {
	options := NewOptions()

	cmd := &cobra.Command{
		Use:           service.ServiceName + "-extension-controller-manager",
		Short:         "DNS Meta Controller for Shoots.",
		SilenceErrors: true,

		RunE: func(cmd *cobra.Command, args []string) error {
			verflag.PrintAndExitIfRequested()
			if err := options.optionAggregator.Complete(); err != nil {
				return fmt.Errorf("error completing options: %s", err)
			}

			if err := options.heartbeatControllerOptions.Validate(); err != nil {
				return err
			}
			cmd.SilenceUsage = true
			return options.run(cmd.Context())
		},
	}

	options.optionAggregator.AddFlags(cmd.Flags())

	return cmd
}

func (o *Options) run(ctx context.Context) error {
	// TODO: Make these flags configurable via command line parameters or component config file.
	util.ApplyClientConnectionConfigurationToRESTConfig(&componentbaseconfigv1alpha1.ClientConnectionConfiguration{
		QPS:   100.0,
		Burst: 130,
	}, o.restOptions.Completed().Config)

	mgrScheme := runtime.NewScheme()
	if err := scheme.AddToScheme(mgrScheme); err != nil {
		return fmt.Errorf("could not update manager scheme (kubernetes): %s", err)
	}
	if err := dnsapi.AddToScheme(mgrScheme); err != nil {
		return fmt.Errorf("could not update manager scheme (dnsapi): %s", err)
	}
	if err := serviceinstall.AddToScheme(mgrScheme); err != nil {
		return fmt.Errorf("could not update manager scheme: %s", err)
	}
	if err := extensionscontroller.AddToScheme(mgrScheme); err != nil {
		return fmt.Errorf("could not update manager scheme: %s", err)
	}
	if err := apiextensionsv1.AddToScheme(mgrScheme); err != nil {
		return fmt.Errorf("could not update manager scheme: %s", err)
	}

	mgrOpts := o.managerOptions.Completed().Options()
	mgrOpts.Scheme = mgrScheme
	mgrOpts.Client = client.Options{
		Cache: &client.CacheOptions{
			DisableFor: []client.Object{
				&corev1.Secret{},    // applied for ManagedResources
				&corev1.ConfigMap{}, // applied for monitoring config
			},
		},
	}
	mgr, err := manager.New(o.restOptions.Completed().Config, mgrOpts)
	if err != nil {
		return fmt.Errorf("could not instantiate controller-manager: %s", err)
	}

	o.serviceOptions.Completed().Apply(&config.DNSService)
	o.healthOptions.Completed().ApplyHealthCheckConfig(&healthcheck.DefaultAddOptions.HealthCheckConfig)
	o.healthControllerOptions.Completed().Apply(&healthcheck.DefaultAddOptions.Controller)
	o.lifecycleControllerOptions.Completed().Apply(&lifecycle.DefaultAddOptions.Controller)
	o.reconcileOptions.Completed().Apply(&lifecycle.DefaultAddOptions.IgnoreOperationAnnotation, nil)
	o.heartbeatControllerOptions.Completed().Apply(&heartbeat.DefaultAddOptions)

	if err := o.controllerSwitches.Completed().AddToManager(ctx, mgr); err != nil {
		return fmt.Errorf("could not add controllers to manager: %s", err)
	}

	// TODO(MartinWeindel): delete after v1.66.0
	if err := mgr.Add(&cleanupDNSOwnerRunnable{client: mgr.GetClient()}); err != nil {
		return fmt.Errorf("could not add cleanupDNSOwnerRunnable: %s", err)
	}

	if err := mgr.Start(ctx); err != nil {
		return fmt.Errorf("error running manager: %s", err)
	}

	return nil
}

type cleanupDNSOwnerRunnable struct {
	client client.Client
}

var _ manager.Runnable = &cleanupDNSOwnerRunnable{}
var _ manager.LeaderElectionRunnable = &cleanupDNSOwnerRunnable{}

func (c *cleanupDNSOwnerRunnable) Start(ctx context.Context) error {
	log := log.Log.WithName("cleanupDNSOwnerRunnable")
	log.Info("Starting cleanup of old DNS owner resources...")
	crd := &apiextensionsv1.CustomResourceDefinition{
		ObjectMeta: metav1.ObjectMeta{
			Name: "dnsowners.dns.gardener.cloud",
		},
	}
	if err := c.client.Get(ctx, client.ObjectKeyFromObject(crd), crd); err != nil {
		if apierrors.IsNotFound(err) {
			log.Info("CRD 'dnsowners.dns.gardener.cloud' not found, nothing to clean up")
			return nil
		}
		log.Error(err, "error getting CRD 'dnsowners.dns.gardener.cloud'")
		return fmt.Errorf("error getting CRD %s: %w", crd.Name, err)
	}
	patch := client.MergeFrom(crd.DeepCopy())
	if crd.Annotations == nil {
		crd.Annotations = make(map[string]string)
	}
	crd.Annotations["confirmation.gardener.cloud/deletion"] = "true"
	if err := c.client.Patch(ctx, crd, patch); err != nil {
		log.Error(err, "error patching CRD 'dnsowners.dns.gardener.cloud'")
		return fmt.Errorf("error patching CRD %s: %w", crd.Name, err)
	}
	if err := c.client.Delete(ctx, crd); err != nil {
		log.Error(err, "error deleting CRD 'dnsowners.dns.gardener.cloud'")
		return fmt.Errorf("error deleting CRD %s: %w", crd.Name, err)
	}
	log.Info("deleted CRD 'dnsowners.dns.gardener.cloud' to clean up old DNS owner resources")
	return nil
}

func (c *cleanupDNSOwnerRunnable) NeedLeaderElection() bool {
	return true
}
