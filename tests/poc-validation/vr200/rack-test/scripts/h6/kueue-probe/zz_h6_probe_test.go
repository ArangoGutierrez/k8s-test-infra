/*
H6 probe (scratch, never committed upstream). Runs Kueue v0.19.5's real
scheduler + TAS cache over a model of the mokka-hetero VR200 tier:
18 KWOK trays sharing one nvidia.com/gpu.clique value, plus the 3 real VR200
workers (no clique label). It answers, by execution, which of the three
designs lets TAS keep one 4-GPU tray pod per node inside one rack.

Copy into pkg/scheduler/ of a v0.19.5 checkout and run:
  go test ./pkg/scheduler/ -run TestH6Probe -count=1 -v
*/

package scheduler

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	testingclock "k8s.io/utils/clock/testing"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/interceptor"

	kueue "sigs.k8s.io/kueue/apis/kueue/v1beta2"
	qcache "sigs.k8s.io/kueue/pkg/cache/queue"
	schdcache "sigs.k8s.io/kueue/pkg/cache/scheduler"
	tasindexer "sigs.k8s.io/kueue/pkg/controller/tas/indexer"
	preemptexpectations "sigs.k8s.io/kueue/pkg/scheduler/preemption/expectations"
	"sigs.k8s.io/kueue/pkg/util/routine"
	"sigs.k8s.io/kueue/pkg/util/tas"
	utiltesting "sigs.k8s.io/kueue/pkg/util/testing"
	utiltestingapi "sigs.k8s.io/kueue/pkg/util/testing/v1beta2"
	testingnode "sigs.k8s.io/kueue/pkg/util/testingjobs/node"
	"sigs.k8s.io/kueue/pkg/workload"
)

const (
	h6Clique    = "nvidia.com/gpu.clique"
	h6GPUType   = "mokka-hetero.nvidia.com/gpu-type"
	h6Shadow    = corev1.ResourceName("mokka-hetero.nvidia.com/tas-gpu")
	h6ExtGPU    = corev1.ResourceName("nvidia.com/gpu")
	h6DRALogic  = corev1.ResourceName("mokka-hetero.nvidia.com/vr200-dra-gpu")
	h6RackValue = "6b0453b6-5432-5c2d-a9b4-f8aa9a7b5739.0" // live vr200 clique (H3 report)
)

var h6KwokTaint = corev1.Taint{Key: "kwok.x-k8s.io/node", Value: "fake", Effect: corev1.TaintEffectNoSchedule}
var h6KwokToleration = corev1.Toleration{Key: "kwok.x-k8s.io/node", Operator: corev1.TolerationOpExists, Effect: corev1.TaintEffectNoSchedule}

// h6Nodes models the VR200 tier. withShadow adds the per-node accounting
// resource (design b) to allocatable; without it, allocatable is what the
// cluster has today (no GPU resource at all).
func h6Nodes(withShadow bool) []corev1.Node {
	var nodes []corev1.Node
	alloc := func(cpu string) corev1.ResourceList {
		rl := corev1.ResourceList{
			corev1.ResourceCPU:    resource.MustParse(cpu),
			corev1.ResourceMemory: resource.MustParse("512Gi"),
			corev1.ResourcePods:   resource.MustParse("110"),
		}
		if withShadow {
			rl[h6Shadow] = resource.MustParse("4")
		}
		return rl
	}
	for i := range 18 {
		name := fmt.Sprintf("kwok-vr200-%02d", i)
		nodes = append(nodes, *testingnode.MakeNode(name).
			Label(h6GPUType, "vr200").
			Label(h6Clique, h6RackValue).
			Label(corev1.LabelHostname, name).
			Taints(h6KwokTaint).
			StatusAllocatable(alloc("64")).
			Ready().
			Obj())
	}
	for i := 7; i <= 9; i++ {
		name := fmt.Sprintf("mokka-hetero-worker%d", i)
		nodes = append(nodes, *testingnode.MakeNode(name).
			Label(h6GPUType, "vr200").
			Label(corev1.LabelHostname, name).
			StatusAllocatable(alloc("4")).
			Ready().
			Obj())
	}
	return nodes
}

type h6Case struct {
	name       string
	withShadow bool
	pods       int32
	required   bool
	podSet     func(*utiltestingapi.PodSetWrapper) *utiltestingapi.PodSetWrapper
	quota      map[corev1.ResourceName]string
	draCharge  corev1.ResourceList // emulates workload_controller.go:582-586
}

func h6Run(t *testing.T, tc h6Case) (admitted bool, perHost map[string]int32, cliques map[string]bool) {
	t.Helper()
	ctx, log := utiltesting.ContextWithLog(t)
	topo := *utiltestingapi.MakeTopology("vr200-rack").Levels(h6Clique, corev1.LabelHostname).Obj()
	flavor := *utiltestingapi.MakeResourceFlavor("vr200").
		NodeLabel(h6GPUType, "vr200").
		TopologyName("vr200-rack").
		Obj()
	fq := utiltestingapi.MakeFlavorQuotas("vr200")
	names := make([]string, 0, len(tc.quota))
	for r := range tc.quota {
		names = append(names, string(r))
	}
	sort.Strings(names)
	for _, r := range names {
		fq = fq.Resource(corev1.ResourceName(r), tc.quota[corev1.ResourceName(r)])
	}
	cq := *utiltestingapi.MakeClusterQueue("vr200").ResourceGroup(*fq.Obj()).Obj()
	lq := *utiltestingapi.MakeLocalQueue("vr200", "default").ClusterQueue("vr200").Obj()

	ps := utiltestingapi.MakePodSet("main", int(tc.pods)).Toleration(h6KwokToleration)
	if tc.required {
		ps = ps.RequiredTopologyRequest(h6Clique)
	} else {
		ps = ps.PreferredTopologyRequest(h6Clique)
	}
	ps = tc.podSet(ps)
	wl := *utiltestingapi.MakeWorkload("tray-job", "default").Queue("vr200").PodSets(*ps.Obj()).Obj()

	nodes := h6Nodes(tc.withShadow)
	// A workload with resourceClaims is diverted by AddLocalQueue to the DRA
	// reconcile channel (queue/manager.go:547-555), which the unit harness does
	// not run. Create it after the LocalQueue instead and hand it to the queue
	// the way the workload controller does (workload_controller.go:582-586).
	var preload []kueue.Workload
	if tc.draCharge == nil {
		preload = []kueue.Workload{wl}
	}
	clientBuilder := utiltesting.NewClientBuilder().
		WithLists(
			&kueue.WorkloadList{Items: preload},
			&kueue.TopologyList{Items: []kueue.Topology{topo}},
			&corev1.NodeList{Items: nodes},
			&kueue.LocalQueueList{Items: []kueue.LocalQueue{lq}}).
		WithObjects(utiltesting.MakeNamespace("default")).
		WithInterceptorFuncs(interceptor.Funcs{SubResourcePatch: utiltesting.TreatSSAAsStrategicMerge}).
		WithStatusSubresource(&kueue.Workload{})
	_ = tasindexer.SetupIndexes(ctx, utiltesting.AsIndexer(clientBuilder))
	cl := clientBuilder.Build()
	recorder := &utiltesting.EventRecorder{}
	cqCache := schdcache.New(cl)
	preemptExp := preemptexpectations.New()
	qManager := qcache.NewManagerForUnitTests(cl, cqCache, qcache.WithPreemptionExpectations(preemptExp))
	for i := range nodes {
		cqCache.TASCache().SyncNode(&nodes[i])
	}
	cqCache.AddOrUpdateResourceFlavor(log, &flavor)
	cqCache.AddOrUpdateTopology(log, &topo)
	if err := cqCache.AddClusterQueue(ctx, &cq); err != nil {
		t.Fatal(err)
	}
	if err := qManager.AddClusterQueue(ctx, &cq); err != nil {
		t.Fatal(err)
	}
	if err := cl.Create(ctx, &cq); err != nil {
		t.Fatal(err)
	}
	if err := qManager.AddLocalQueue(ctx, &lq); err != nil {
		t.Fatal(err)
	}
	if tc.draCharge != nil {
		if err := cl.Create(ctx, wl.DeepCopy()); err != nil {
			t.Fatal(err)
		}
		// What the workload controller does after DRA preprocessing.
		opt := workload.WithPreprocessedDRAResources(map[kueue.PodSetReference]corev1.ResourceList{"main": tc.draCharge}, nil)
		if err := qManager.AddOrUpdateWorkload(log, wl.DeepCopy(), opt); err != nil {
			t.Fatal(err)
		}
	}
	sched := New(qManager, cqCache, cl, recorder, WithClock(t, testingclock.NewFakeClock(time.Now())), WithPreemptionExpectations(preemptExp))
	wg := sync.WaitGroup{}
	sched.setAdmissionRoutineWrapper(routine.NewWrapper(func() { wg.Add(1) }, func() { wg.Done() }))
	sctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	go qManager.CleanUpOnContext(sctx)
	sched.schedule(sctx)
	wg.Wait()

	w := kueue.Workload{}
	if err := cl.Get(ctx, client.ObjectKeyFromObject(&wl), &w); err != nil {
		t.Fatal(err)
	}
	perHost = map[string]int32{}
	cliques = map[string]bool{}
	if w.Status.Admission == nil {
		for _, c := range w.Status.Conditions {
			t.Logf("  condition %s=%s reason=%s msg=%q", c.Type, c.Status, c.Reason, c.Message)
		}
		return false, perHost, cliques
	}
	psa := w.Status.Admission.PodSetAssignments[0]
	t.Logf("  admitted; resourceUsage=%v levels=%v", psa.ResourceUsage, psa.TopologyAssignment.Levels)
	nodeClique := map[string]string{}
	for i := range nodes {
		nodeClique[nodes[i].Labels[corev1.LabelHostname]] = nodes[i].Labels[h6Clique]
	}
	for d := range tas.InternalSeqFrom(psa.TopologyAssignment) {
		host := d.Values[len(d.Values)-1]
		perHost[host] += d.Count
		// With hostname as the lowest level Kueue records only that level, so
		// the rack is read back from the chosen node's label.
		cliques[nodeClique[host]] = true
	}
	keys := make([]string, 0, len(perHost))
	for k := range perHost {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		fmt.Fprintf(&b, "%s=%d ", k, perHost[k])
	}
	t.Logf("  per-host pod counts: %s", b.String())
	return true, perHost, cliques
}

func TestH6Probe(t *testing.T) {
	shadow4 := func(p *utiltestingapi.PodSetWrapper) *utiltestingapi.PodSetWrapper {
		return p.Request(h6Shadow, "4")
	}
	extGPU4 := func(p *utiltestingapi.PodSetWrapper) *utiltestingapi.PodSetWrapper {
		return p.Request(h6ExtGPU, "4")
	}
	draOnly := func(p *utiltestingapi.PodSetWrapper) *utiltestingapi.PodSetWrapper {
		// No container requests at all, like busybox in s3-rack-a.yaml; the
		// GPUs live only in the claim.
		return p.ResourceClaimTemplate("gpus", "vr200-x4")
	}

	t.Run("b/18 trays, shadow resource, required clique", func(t *testing.T) {
		ok, perHost, cliques := h6Run(t, h6Case{withShadow: true, pods: 18, required: true, podSet: shadow4,
			quota: map[corev1.ResourceName]string{h6Shadow: "84"}})
		if !ok {
			t.Fatalf("want admitted")
		}
		if len(perHost) != 18 || len(cliques) != 1 || !cliques[h6RackValue] {
			t.Fatalf("want 18 hosts in clique %s, got hosts=%d cliques=%v", h6RackValue, len(perHost), cliques)
		}
		for h, n := range perHost {
			if n != 1 || !strings.HasPrefix(h, "kwok-vr200-") {
				t.Fatalf("want exactly one pod per rack tray, got %s=%d", h, n)
			}
		}
	})
	t.Run("b/19 trays, shadow resource, required clique (21 trays exist, 18 in the rack)", func(t *testing.T) {
		ok, _, _ := h6Run(t, h6Case{withShadow: true, pods: 19, required: true, podSet: shadow4,
			quota: map[corev1.ResourceName]string{h6Shadow: "84"}})
		if ok {
			t.Fatalf("want NOT admitted: the rack has 18 trays")
		}
	})
	t.Run("b/19 trays, shadow resource, PREFERRED clique (real nodes lack the level label)", func(t *testing.T) {
		ok, _, _ := h6Run(t, h6Case{withShadow: true, pods: 19, required: false, podSet: shadow4,
			quota: map[corev1.ResourceName]string{h6Shadow: "84"}})
		if ok {
			t.Fatalf("want NOT admitted: the 3 real workers are outside the TAS flavor")
		}
	})
	t.Run("a/18 trays, nvidia.com/gpu request, no allocatable (DRAExtendedResource shape)", func(t *testing.T) {
		ok, _, _ := h6Run(t, h6Case{withShadow: false, pods: 18, required: true, podSet: extGPU4,
			quota: map[corev1.ResourceName]string{h6ExtGPU: "84"}})
		if ok {
			t.Fatalf("want NOT admitted: TAS reads node allocatable, which has no nvidia.com/gpu")
		}
	})
	t.Run("c/18 trays, DRA claim only (no container requests), quota via deviceClassMappings", func(t *testing.T) {
		// Observed in run 4: nominated on the DRA quota, then rejected by the
		// post-nomination TAS fit check, because the pod spec requests nothing
		// and CountIn of an empty request list is 0 (pkg/resources/requests.go:227).
		ok, _, _ := h6Run(t, h6Case{withShadow: false, pods: 18, required: true, podSet: draOnly,
			quota:     map[corev1.ResourceName]string{h6DRALogic: "84"},
			draCharge: corev1.ResourceList{h6DRALogic: resource.MustParse("4")}})
		if ok {
			t.Fatalf("want NOT admitted: a TAS pod set with no container requests never passes cq.Fits")
		}
	})
	t.Run("c2/18 trays, DRA claim + cpu 100m, quota charged via deviceClassMappings", func(t *testing.T) {
		draCPU := func(p *utiltestingapi.PodSetWrapper) *utiltestingapi.PodSetWrapper {
			return p.ResourceClaimTemplate("gpus", "vr200-x4").Request(corev1.ResourceCPU, "100m")
		}
		ok, perHost, cliques := h6Run(t, h6Case{withShadow: false, pods: 18, required: true, podSet: draCPU,
			quota:     map[corev1.ResourceName]string{h6DRALogic: "84", corev1.ResourceCPU: "100"},
			draCharge: corev1.ResourceList{h6DRALogic: resource.MustParse("4")}})
		if !ok {
			t.Fatalf("want admitted")
		}
		maxPerHost := int32(0)
		for _, n := range perHost {
			maxPerHost = max(maxPerHost, n)
		}
		t.Logf("  hosts used=%d, max pods on one host=%d, cliques=%v (a tray holds one 4-GPU pod)", len(perHost), maxPerHost, cliques)
		if maxPerHost <= 1 {
			t.Fatalf("expected TAS to stack DRA-only pods on a host; it did not")
		}
	})
	t.Run("q0/18 pods with no requests at all, no DRA (isolates the empty-request case)", func(t *testing.T) {
		none := func(p *utiltestingapi.PodSetWrapper) *utiltestingapi.PodSetWrapper { return p }
		ok, _, _ := h6Run(t, h6Case{withShadow: false, pods: 18, required: true, podSet: none,
			quota: map[corev1.ResourceName]string{corev1.ResourceCPU: "100"}})
		t.Logf("  admitted=%v", ok)
	})
}

// TestH6ProbeSecondJob runs two scheduling cycles over two identical 18-tray
// workloads (design b): the first must be admitted, the second held by TAS
// while the ClusterQueue still has quota (144 >> 72), and its message is the
// string k7-tas-check.sh T3 matches.
func TestH6ProbeSecondJob(t *testing.T) {
	ctx, log := utiltesting.ContextWithLog(t)
	topo := *utiltestingapi.MakeTopology("mokka-hetero-rack").Levels(h6Clique, corev1.LabelHostname).Obj()
	flavor := *utiltestingapi.MakeResourceFlavor("vr200-rack").NodeLabel(h6GPUType, "vr200").TopologyName("mokka-hetero-rack").Obj()
	cq := *utiltestingapi.MakeClusterQueue("vr200").ResourceGroup(*utiltestingapi.MakeFlavorQuotas("vr200-rack").
		Resource(h6Shadow, "144").Obj()).Obj()
	lq := *utiltestingapi.MakeLocalQueue("vr200", "default").ClusterQueue("vr200").Obj()
	mk := func(name string, created time.Time) kueue.Workload {
		ps := utiltestingapi.MakePodSet("main", 18).Toleration(h6KwokToleration).RequiredTopologyRequest(h6Clique).Request(h6Shadow, "4")
		return *utiltestingapi.MakeWorkload(name, "default").Queue("vr200").Creation(created).PodSets(*ps.Obj()).Obj()
	}
	now := time.Now().Truncate(time.Second)
	wlA, wlB := mk("tas-a", now.Add(-time.Minute)), mk("tas-b", now)
	nodes := h6Nodes(true)
	clientBuilder := utiltesting.NewClientBuilder().
		WithLists(
			&kueue.WorkloadList{Items: []kueue.Workload{wlA, wlB}},
			&kueue.TopologyList{Items: []kueue.Topology{topo}},
			&corev1.NodeList{Items: nodes},
			&kueue.LocalQueueList{Items: []kueue.LocalQueue{lq}}).
		WithObjects(utiltesting.MakeNamespace("default")).
		WithInterceptorFuncs(interceptor.Funcs{SubResourcePatch: utiltesting.TreatSSAAsStrategicMerge}).
		WithStatusSubresource(&kueue.Workload{})
	_ = tasindexer.SetupIndexes(ctx, utiltesting.AsIndexer(clientBuilder))
	cl := clientBuilder.Build()
	cqCache := schdcache.New(cl)
	preemptExp := preemptexpectations.New()
	qManager := qcache.NewManagerForUnitTests(cl, cqCache, qcache.WithPreemptionExpectations(preemptExp))
	for i := range nodes {
		cqCache.TASCache().SyncNode(&nodes[i])
	}
	cqCache.AddOrUpdateResourceFlavor(log, &flavor)
	cqCache.AddOrUpdateTopology(log, &topo)
	if err := cqCache.AddClusterQueue(ctx, &cq); err != nil {
		t.Fatal(err)
	}
	if err := qManager.AddClusterQueue(ctx, &cq); err != nil {
		t.Fatal(err)
	}
	if err := cl.Create(ctx, &cq); err != nil {
		t.Fatal(err)
	}
	if err := qManager.AddLocalQueue(ctx, &lq); err != nil {
		t.Fatal(err)
	}
	sched := New(qManager, cqCache, cl, &utiltesting.EventRecorder{}, WithClock(t, testingclock.NewFakeClock(now)), WithPreemptionExpectations(preemptExp))
	wg := sync.WaitGroup{}
	sched.setAdmissionRoutineWrapper(routine.NewWrapper(func() { wg.Add(1) }, func() { wg.Done() }))
	sctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	go qManager.CleanUpOnContext(sctx)
	for range 2 {
		sched.schedule(sctx)
		wg.Wait()
	}
	get := func(w kueue.Workload) kueue.Workload {
		got := kueue.Workload{}
		if err := cl.Get(ctx, client.ObjectKeyFromObject(&w), &got); err != nil {
			t.Fatal(err)
		}
		return got
	}
	a, b := get(wlA), get(wlB)
	if a.Status.Admission == nil {
		t.Fatalf("want tas-a admitted, conditions=%v", a.Status.Conditions)
	}
	t.Logf("tas-a admitted: usage=%v", a.Status.Admission.PodSetAssignments[0].ResourceUsage)
	if b.Status.Admission != nil {
		t.Fatalf("want tas-b NOT admitted while tas-a holds the rack")
	}
	msg := ""
	for _, c := range b.Status.Conditions {
		t.Logf("tas-b condition %s=%s reason=%s msg=%q", c.Type, c.Status, c.Reason, c.Message)
		if c.Type == kueue.WorkloadQuotaReserved {
			msg = c.Message
		}
	}
	if !strings.Contains(msg, `topology "mokka-hetero-rack"`) {
		t.Fatalf("want a topology reason for tas-b, got %q", msg)
	}
}
