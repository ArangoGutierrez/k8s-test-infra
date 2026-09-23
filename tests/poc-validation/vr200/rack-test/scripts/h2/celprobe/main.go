// celprobe compiles the H2 claim-template selectors with the Kubernetes
// v0.35.0 DRA CEL compiler and evaluates them against the attribute sets the
// DRA driver v0.5.0 publishes for each Mokka profile (values from
// dra-driver/hack/h2probe). It prints a match matrix; exit 1 if any
// template matches a type other than its own.
package main

import (
	"context"
	"fmt"
	"os"
	"strings"

	resourceapi "k8s.io/api/resource/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	dracel "k8s.io/dynamic-resource-allocation/cel"
	"sigs.k8s.io/yaml"
)

func s(v string) resourceapi.DeviceAttribute  { return resourceapi.DeviceAttribute{StringValue: &v} }
func ver(v string) resourceapi.DeviceAttribute { return resourceapi.DeviceAttribute{VersionValue: &v} }

func device(product, arch, cc, driver, cuda, bdf, mem string) dracel.Device {
	return dracel.Device{
		Driver: "gpu.nvidia.com",
		Attributes: map[resourceapi.QualifiedName]resourceapi.DeviceAttribute{
			"type": s("gpu"), "uuid": s("GPU-x"), "productName": s(product), "brand": s("Nvidia"),
			"architecture": s(arch), "cudaComputeCapability": ver(cc), "driverVersion": ver(driver),
			"cudaDriverVersion": ver(cuda), "resource.kubernetes.io/pciBusID": s(bdf),
		},
		Capacity: map[resourceapi.QualifiedName]resourceapi.DeviceCapacity{
			"memory": {Value: resource.MustParse(mem)},
		},
	}
}

func main() {
	types := []struct {
		name string
		dev  dracel.Device
	}{
		{"h100", device("NVIDIA H100 80GB HBM3", "Hopper", "9.0.0", "550.163.1", "12.4.0", "0000:1a:00.0", "80Gi")},
		{"gb300", device("NVIDIA GB300 NVL", "Blackwell", "10.0.0", "570.124.6", "12.8.0", "0000:0a:00.0", "288Gi")},
		{"vr200", device("NVIDIA Graphics Device", "Rubin", "10.7.0", "615.23.0", "13.4.0", "0002:81:00.0", "288Gi")},
		// What a real GB300 would publish if it reports cc 10.3 (SPEC known unknown).
		{"gb300-cc10.3", device("NVIDIA GB300 NVL", "Blackwell", "10.3.0", "570.124.6", "12.8.0", "0000:0a:00.0", "288Gi")},
	}

	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	type sel struct{ name, expr string }
	var sels []sel
	for _, doc := range strings.Split(string(data), "\n---\n") {
		if !strings.Contains(doc, "kind: ResourceClaimTemplate") {
			continue
		}
		t := &resourceapi.ResourceClaimTemplate{}
		if err := yaml.UnmarshalStrict([]byte(doc), t); err != nil {
			fmt.Println("STRICT DECODE FAIL:", err)
			os.Exit(1)
		}
		r := t.Spec.Spec.Devices.Requests[0]
		if r.Exactly == nil || r.Exactly.DeviceClassName != "gpu.nvidia.com" || len(r.Exactly.Selectors) != 1 {
			fmt.Println("unexpected request shape in", t.Name)
			os.Exit(1)
		}
		sels = append(sels, sel{t.Name, r.Exactly.Selectors[0].CEL.Expression})
	}
	// Naive selectors, to show which single attributes do NOT discriminate.
	naive := []sel{
		{"naive:deviceclass", "device.driver == 'gpu.nvidia.com' && device.attributes['gpu.nvidia.com'].type == 'gpu'"},
		{"naive:cc-major-10", "device.attributes['gpu.nvidia.com'].cudaComputeCapability.major() == 10"},
		{"naive:cc>=10.0", "!device.attributes['gpu.nvidia.com'].cudaComputeCapability.isLessThan(semver('10.0.0'))"},
		{"naive:mem-288Gi", "device.capacity['gpu.nvidia.com'].memory.compareTo(quantity('288Gi')) == 0"},
		{"naive:brand", "device.attributes['gpu.nvidia.com'].brand == 'Nvidia'"},
		{"naive:arch-Blackwell", "device.attributes['gpu.nvidia.com'].architecture == 'Blackwell'"},
		{"naive:arch-Rubin", "device.attributes['gpu.nvidia.com'].architecture == 'Rubin'"},
	}

	compiler := dracel.GetCompiler(dracel.Features{})
	bad := false
	fmt.Printf("%-22s", "selector \\ device")
	for _, ty := range types {
		fmt.Printf(" %-13s", ty.name)
	}
	fmt.Println()
	for _, sl := range append(sels, naive...) {
		res := compiler.CompileCELExpression(sl.expr, dracel.Options{})
		if res.Error != nil {
			fmt.Println("COMPILE FAIL", sl.name, res.Error)
			os.Exit(1)
		}
		fmt.Printf("%-22s", sl.name)
		for _, ty := range types {
			m, _, err := res.DeviceMatches(context.Background(), ty.dev)
			if err != nil {
				fmt.Printf(" ERR(%v)", err)
				bad = true
				continue
			}
			fmt.Printf(" %-13v", m)
			if !strings.HasPrefix(sl.name, "naive:") {
				own := strings.TrimSuffix(sl.name, "-x1")
				own = strings.TrimSuffix(own, "-x4")
				if m != (ty.name == own) {
					bad = true
				}
			}
		}
		fmt.Println()
	}
	if bad {
		fmt.Println("RESULT: a claim template is not type-exclusive")
		os.Exit(1)
	}
	fmt.Println("RESULT: every claim template matches only its own type")
}
