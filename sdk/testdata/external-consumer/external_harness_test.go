package externalconsumer_test

import (
	"context"
	"testing"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"go.uber.org/mock/gomock"

	"github.com/candace-server/pkg/candaceos/harness"
	candaceosv1 "github.com/candace-server/proto/candace/candaceos/v1"

	"example.com/candaceos-external-consumer/customharness"
	"example.com/candaceos-external-consumer/steering"
)

func TestExternalConsumer(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "External CandaceOS Consumer Suite")
}

var _ harness.Host = (*MockHost)(nil)

var _ = Describe("an external harness", func() {
	It("publishes through the SDK host", func() {
		controller := gomock.NewController(GinkgoT())
		host := NewMockHost(controller)
		gomock.InOrder(
			host.EXPECT().Publish(gomock.Any(), gomock.Any()).DoAndReturn(
				func(ctx context.Context, event *candaceosv1.HarnessEvent) error {
					Expect(ctx).NotTo(BeNil())
					Expect(event.GetRunId()).To(Equal("external-run-1"))
					Expect(event.GetAssistantMessage()).NotTo(BeNil())
					Expect(event.GetAssistantMessage().GetContent()).To(Equal("external echo: hello from another repository"))
					return nil
				},
			),
			host.EXPECT().Publish(gomock.Any(), gomock.Any()).DoAndReturn(
				func(ctx context.Context, event *candaceosv1.HarnessEvent) error {
					Expect(ctx).NotTo(BeNil())
					Expect(event.GetRunId()).To(Equal("external-run-1"))
					Expect(event.GetIdle()).NotTo(BeNil())
					return nil
				},
			),
		)

		instance, err := customharness.NewFactory(steering.Instance()).New(&candaceosv1.HarnessContext{
			Workspace: "/external/workspace",
		}, host)
		Expect(err).NotTo(HaveOccurred())
		Expect(instance.Identity).To(Equal(&candaceosv1.HarnessRuntimeIdentity{
			Backend:        candaceosv1.HarnessBackend_HARNESS_BACKEND_EMBEDDED,
			Implementation: "external-echo",
			Model:          "echo-v1",
		}))

		session, err := instance.Runtime.Start(context.Background())
		Expect(err).NotTo(HaveOccurred())
		Expect(session.GetId()).To(Equal("external-echo-session"))
		Expect(instance.Runtime.Activate(context.Background())).To(Succeed())
		Expect(instance.Runtime.Send(context.Background(), &candaceosv1.HarnessPrompt{
			RunId:    "external-run-1",
			Content:  "hello from another repository",
			Delivery: candaceosv1.HarnessDelivery_HARNESS_DELIVERY_IMMEDIATE,
		})).To(Succeed())
		Expect(instance.Runtime.Close()).To(Succeed())
	})
})
