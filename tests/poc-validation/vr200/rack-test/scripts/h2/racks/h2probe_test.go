// SPDX-License-Identifier: Apache-2.0

// Throwaway probe, injected with `go test -overlay` so the read-only tree is
// not modified. It checks the H2 rack drafts against (1) the real CRD
// OpenAPI schema and its x-kubernetes-validations, (2) the typed structs with
// strict decoding, and (3) the control plane's own materialization, then
// prints the SGPURack identities the controller would derive.
package v1alpha1_test

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
	apiextensions "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions"
	apixv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	structuralschema "k8s.io/apiextensions-apiserver/pkg/apiserver/schema"
	schemacel "k8s.io/apiextensions-apiserver/pkg/apiserver/schema/cel"
	"k8s.io/apiextensions-apiserver/pkg/apiserver/validation"
	"k8s.io/apimachinery/pkg/types"
	utiljson "k8s.io/apimachinery/pkg/util/json"
	"k8s.io/apimachinery/pkg/util/validation/field"
	celconfig "k8s.io/apiserver/pkg/apis/cel"
	"sigs.k8s.io/yaml"

	mokkav1alpha1 "github.com/NVIDIA/k8s-test-infra/internal/controlplane/api/v1alpha1"
	rackrender "github.com/NVIDIA/k8s-test-infra/internal/sgpu/inventory/rack"
)

const h2Dir = "/tmp/mokka-hetero-58fc971e/h2/racks"

func h2Docs(t *testing.T, file string) []string {
	t.Helper()
	data, err := os.ReadFile(filepath.Join(h2Dir, file))
	require.NoError(t, err)
	var docs []string
	for _, d := range strings.Split(string(data), "\n---\n") {
		if strings.Contains(d, "kind:") {
			docs = append(docs, d)
		}
	}
	return docs
}

func h2SchemaValidate(t *testing.T, crdFile, doc string) {
	t.Helper()
	path := filepath.Join("..", "..", "..", "..", "deployments", "mokka-crds", "helm", "mokka-crds", "templates", crdFile)
	raw, err := os.ReadFile(path)
	require.NoError(t, err)
	crd := &apixv1.CustomResourceDefinition{}
	require.NoError(t, yaml.Unmarshal(raw, crd))
	internal := &apiextensions.JSONSchemaProps{}
	require.NoError(t, apixv1.Convert_v1_JSONSchemaProps_To_apiextensions_JSONSchemaProps(crd.Spec.Versions[0].Schema.OpenAPIV3Schema, internal, nil))

	// Decode the way the apiserver does: YAML -> JSON -> apimachinery json,
	// which keeps whole numbers as int64 (CEL rules compare ints).
	js, err := yaml.YAMLToJSON([]byte(doc))
	require.NoError(t, err)
	obj := map[string]any{}
	require.NoError(t, utiljson.Unmarshal(js, &obj))

	validator, _, err := validation.NewSchemaValidator(internal)
	require.NoError(t, err)
	errs := validation.ValidateCustomResource(field.NewPath(""), obj, validator)
	require.Empty(t, errs, "openapi schema errors")

	ss, err := structuralschema.NewStructural(internal)
	require.NoError(t, err)
	celErrs, _ := schemacel.NewValidator(ss, true, celconfig.PerCallLimit).Validate(context.Background(), field.NewPath(""), ss, obj, nil, celconfig.RuntimeCELCostBudget)
	require.Empty(t, celErrs, "x-kubernetes-validations errors")
}

func TestH2RackDrafts(t *testing.T) {
	profiles := map[string]*mokkav1alpha1.SGPURackProfile{}
	for _, doc := range h2Docs(t, "sgpu-rack-profiles.yaml") {
		h2SchemaValidate(t, "mokka.nvidia.com_sgpurackprofiles.yaml", doc)
		p := &mokkav1alpha1.SGPURackProfile{}
		require.NoError(t, yaml.UnmarshalStrict([]byte(doc), p))
		require.NoError(t, rackrender.ValidateProfile(p.Spec), p.Name)
		p.UID = types.UID("00000000-0000-0000-0000-00000000000" + string(rune('a'+len(profiles))))
		p.Generation = 1
		profiles[p.Name] = p
	}
	require.Len(t, profiles, 3)

	invDocs := h2Docs(t, "sgpu-inventory.yaml")
	require.Len(t, invDocs, 1)
	h2SchemaValidate(t, "mokka.nvidia.com_sgpuinventories.yaml", invDocs[0])
	inv := &mokkav1alpha1.SGPUInventory{}
	require.NoError(t, yaml.UnmarshalStrict([]byte(invDocs[0]), inv))

	invUID := types.UID("11111111-2222-3333-4444-555555555555")
	total := 0
	for _, g := range inv.Spec.RackGroups {
		p := profiles[g.ProfileRef.Name]
		require.NotNil(t, p, g.ProfileRef.Name)
		r, err := rackrender.RenderRack(rackrender.RackInput{
			InventoryName: inv.Name, InventoryUID: invUID, Group: g, RackIndex: 0, Profile: p,
		})
		require.NoError(t, err)
		gpus := 0
		for _, n := range r.Spec.Nodes {
			gpus += len(n.GPUs)
		}
		total += gpus
		t.Logf("group=%s rack=%s nodes=%d gpus=%d clique=%s.%d node0.gpu0=%s@%s node17.gpu%d=%s@%s",
			g.ID, r.Name, len(r.Spec.Nodes), gpus, r.Spec.Identity.FabricUUID, r.Spec.Identity.CliqueID,
			r.Spec.Nodes[0].GPUs[0].UUID, r.Spec.Nodes[0].GPUs[0].PCIAddress,
			len(r.Spec.Nodes[17].GPUs)-1, r.Spec.Nodes[17].GPUs[len(r.Spec.Nodes[17].GPUs)-1].UUID,
			r.Spec.Nodes[17].GPUs[len(r.Spec.Nodes[17].GPUs)-1].PCIAddress)
	}
	t.Logf("total KWOK GPUs described by racks: %d", total)
	require.Equal(t, 72+72+144, total)
}

// The HGX H100 NVLink domain is the node. Declaring that honestly
// (scope Node, gpuCount 8) passes CRD admission but not materialization.
func TestH2H100NodeScopedFabricIsRejected(t *testing.T) {
	var h100 string
	for _, doc := range h2Docs(t, "sgpu-rack-profiles.yaml") {
		if strings.Contains(doc, "name: hetero-h100-hgx") {
			h100 = doc
		}
	}
	require.NotEmpty(t, h100)
	withFabric := strings.Replace(h100, "      network:", `      gpuFabric:
        type: NVLink
        generation: 4
        linksPerGPU: 18
        bandwidthPerLinkMBps: 26562
        domain:
          scope: Node
          gpuCount: 8
      network:`, 1)
	require.NotEqual(t, h100, withFabric)
	h2SchemaValidate(t, "mokka.nvidia.com_sgpurackprofiles.yaml", withFabric)
	p := &mokkav1alpha1.SGPURackProfile{}
	require.NoError(t, yaml.UnmarshalStrict([]byte(withFabric), p))
	err := rackrender.ValidateProfile(p.Spec)
	require.EqualError(t, err, "gpuFabric must define a positive rack-scoped topology")
}
