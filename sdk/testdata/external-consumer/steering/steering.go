// Package steering composes an agent-steering service alongside CandaceOS
// Core. Both values belong to this repository: Core constructs neither, reads
// neither one's configuration, and hands neither any Core state. Core owns only
// the order — the store is assembled and started before the service and stopped
// after it.
package steering

import (
	"context"
	"errors"
	"fmt"
	"sync"

	"github.com/candace-server/pkg/candaceos/component"
)

// Capacity bounds the steering inputs retained in memory.
const Capacity = 32

// ErrUnassembled reports use of a steering value before Core assembled it.
var ErrUnassembled = errors.New("steering: component is not assembled")

// The component closures below are the only writers of these values. Core
// injects nothing: the embedding repository owns whatever its components build.
var (
	steeringStore   = &Store{}
	steeringService = &Service{}
)

// Store retains a bounded, newest-last window of operator steering inputs.
type Store struct {
	mutex    sync.Mutex
	capacity int
	inputs   []string
}

// Append records one steering input and discards the oldest beyond capacity.
func (store *Store) Append(input string) error {
	store.mutex.Lock()
	defer store.mutex.Unlock()
	if store.capacity == 0 {
		return ErrUnassembled
	}
	store.inputs = append(store.inputs, input)
	if len(store.inputs) > store.capacity {
		store.inputs = store.inputs[len(store.inputs)-store.capacity:]
	}
	return nil
}

// Inputs returns the retained steering inputs, oldest first.
func (store *Store) Inputs() []string {
	store.mutex.Lock()
	defer store.mutex.Unlock()
	return append([]string(nil), store.inputs...)
}

// Service records the steering inputs the harness observes. It is the value the
// harness factory captures; its store binding arrives when Core assembles the
// steering-service component.
type Service struct {
	mutex   sync.Mutex
	store   *Store
	running bool
}

// Observe records one steering input. A service that is not running drops the
// input, so the harness never depends on Core's bring-up order itself.
func (service *Service) Observe(input string) {
	service.mutex.Lock()
	store, running := service.store, service.running
	service.mutex.Unlock()
	if store == nil || !running {
		return
	}
	_ = store.Append(input)
}

// Observed returns the steering inputs this service recorded, oldest first.
func (service *Service) Observed() []string {
	service.mutex.Lock()
	store := service.store
	service.mutex.Unlock()
	if store == nil {
		return nil
	}
	return store.Inputs()
}

// Instance returns the steering service this binary hands to its harness
// factory. The value exists before Core runs; the steering-service component
// fills in its store binding during assembly.
func Instance() *Service { return steeringService }

// StoreComponent returns the definition that assembles the bounded steering
// store. The closure owns the whole value; nothing is injected into it.
func StoreComponent() (*component.Definition, error) {
	return component.New(
		"steering-store",
		component.WithAssemble(func(ctx context.Context, capabilities component.Capabilities) error {
			steeringStore.mutex.Lock()
			steeringStore.capacity = Capacity
			steeringStore.inputs = make([]string, 0, Capacity)
			steeringStore.mutex.Unlock()
			return capabilities.Log(
				ctx,
				"assembled",
				fmt.Sprintf("steering store retains %d inputs", Capacity),
			)
		}),
	)
}

// ServiceComponent returns the definition that assembles the steering service.
// It requires the store definition by pointer identity, so Core assembles and
// starts the store first and stops it last.
func ServiceComponent(storeComponent *component.Definition) (*component.Definition, error) {
	return component.New(
		"steering-service",
		component.WithRequires(storeComponent),
		component.WithAssemble(func(ctx context.Context, capabilities component.Capabilities) error {
			steeringService.mutex.Lock()
			steeringService.store = steeringStore
			steeringService.mutex.Unlock()
			return capabilities.Log(ctx, "assembled", "steering service bound to the steering store")
		}),
		component.WithStart(func(ctx context.Context) error {
			steeringService.mutex.Lock()
			defer steeringService.mutex.Unlock()
			if steeringService.store == nil {
				return ErrUnassembled
			}
			steeringService.running = true
			return ctx.Err()
		}),
		component.WithStop(func(context.Context) error {
			steeringService.mutex.Lock()
			defer steeringService.mutex.Unlock()
			steeringService.running = false
			return nil
		}),
	)
}
