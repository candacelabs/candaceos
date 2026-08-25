package main

import (
	"github.com/candace-server/services/candaceos-core/bootstrap"

	"example.com/candaceos-external-consumer/customharness"
	"example.com/candaceos-external-consumer/steering"
)

func main() {
	steeringStore, err := steering.StoreComponent()
	if err != nil {
		panic(err)
	}
	steeringService, err := steering.ServiceComponent(steeringStore)
	if err != nil {
		panic(err)
	}
	if err := bootstrap.Run(
		"external-consumer",
		bootstrap.WithComponent(steeringStore),
		bootstrap.WithComponent(steeringService),
		bootstrap.WithHarnessFactory(customharness.NewFactory(steering.Instance())),
	); err != nil {
		panic(err)
	}
}
