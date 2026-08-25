package externalconsumer_test

import (
	"context"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/candace-server/pkg/candaceos/component"

	"example.com/candaceos-external-consumer/steering"
)

// These specs need no Core, no PostgreSQL, and no network: component.Order is a
// pure function over definitions this repository built itself.

func steeringComponents() (*component.Definition, *component.Definition) {
	GinkgoHelper()
	storeComponent, err := steering.StoreComponent()
	Expect(err).NotTo(HaveOccurred())
	serviceComponent, err := steering.ServiceComponent(storeComponent)
	Expect(err).NotTo(HaveOccurred())
	return storeComponent, serviceComponent
}

func standaloneComponent(name string) *component.Definition {
	GinkgoHelper()
	definition, err := component.New(name, component.WithAssemble(
		func(context.Context, component.Capabilities) error { return nil },
	))
	Expect(err).NotTo(HaveOccurred())
	return definition
}

func resolvedNames(definitions ...*component.Definition) []string {
	GinkgoHelper()
	resolved, err := component.Order(definitions...)
	Expect(err).NotTo(HaveOccurred())
	names := make([]string, 0, len(resolved))
	for _, definition := range resolved {
		names = append(names, definition.Name())
	}
	return names
}

var _ = Describe("composed component ordering", func() {
	It("resolves a requirement before the component that declares it", func() {
		storeComponent, serviceComponent := steeringComponents()

		Expect(resolvedNames(storeComponent, serviceComponent)).
			To(Equal([]string{"steering-store", "steering-service"}))
		Expect(resolvedNames(serviceComponent, storeComponent)).
			To(Equal([]string{"steering-store", "steering-service"}))
	})

	It("breaks ties between independent components in registration order", func() {
		audit := standaloneComponent("steering-audit")
		metrics := standaloneComponent("steering-metrics")

		Expect(resolvedNames(audit, metrics)).
			To(Equal([]string{"steering-audit", "steering-metrics"}))
		Expect(resolvedNames(metrics, audit)).
			To(Equal([]string{"steering-metrics", "steering-audit"}))
	})

	It("applies the tie-break to components a requirement releases", func() {
		storeComponent, serviceComponent := steeringComponents()
		audit := standaloneComponent("steering-audit")

		Expect(resolvedNames(serviceComponent, audit, storeComponent)).
			To(Equal([]string{"steering-audit", "steering-store", "steering-service"}))
	})

	It("names both components when a requirement is not registered", func() {
		_, serviceComponent := steeringComponents()

		_, err := component.Order(serviceComponent)
		Expect(err).To(MatchError(component.ErrMissingRequirement))
		Expect(err.Error()).To(ContainSubstring("steering-service"))
		Expect(err.Error()).To(ContainSubstring("steering-store"))
	})

	It("keeps a consumer graph acyclic by construction", func() {
		// Requirements are declared by pointer identity, so an edge can only
		// point at an already-constructed definition: an embedding repository
		// cannot express a cycle at all. The resolver still reports one for
		// Core's own graph, naming the full path, as in
		// "component: dependency cycle: a -> b -> c -> a".
		Expect(component.ErrDependencyCycle.Error()).To(ContainSubstring("dependency cycle"))

		storeComponent, serviceComponent := steeringComponents()
		Expect(resolvedNames(storeComponent, serviceComponent)).To(HaveLen(2))
	})
})
