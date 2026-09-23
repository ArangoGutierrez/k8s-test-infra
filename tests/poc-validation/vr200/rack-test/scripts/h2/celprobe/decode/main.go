// decode strictly unmarshals every document of the given files into the
// typed k8s.io/api v0.35.0 struct for its kind; an unknown or misspelt field
// fails the run.
package main

import (
	"fmt"
	"os"
	"strings"

	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	resourcev1 "k8s.io/api/resource/v1"
	"sigs.k8s.io/yaml"
)

func main() {
	bad := 0
	for _, f := range os.Args[1:] {
		data, err := os.ReadFile(f)
		if err != nil {
			panic(err)
		}
		for _, doc := range strings.Split(string(data), "\n---\n") {
			var meta struct{ Kind string }
			if err := yaml.Unmarshal([]byte(doc), &meta); err != nil || meta.Kind == "" {
				continue
			}
			var obj any
			switch meta.Kind {
			case "Deployment":
				obj = &appsv1.Deployment{}
			case "Job":
				obj = &batchv1.Job{}
			case "Pod":
				obj = &corev1.Pod{}
			case "Node":
				obj = &corev1.Node{}
			case "Namespace":
				obj = &corev1.Namespace{}
			case "ResourceClaimTemplate":
				obj = &resourcev1.ResourceClaimTemplate{}
			case "ResourceSlice":
				obj = &resourcev1.ResourceSlice{}
			default:
				fmt.Printf("%s: skip kind %s\n", f, meta.Kind)
				continue
			}
			if err := yaml.UnmarshalStrict([]byte(doc), obj); err != nil {
				fmt.Printf("%s: %s: %v\n", f, meta.Kind, err)
				bad++
			}
		}
	}
	if bad > 0 {
		os.Exit(1)
	}
	fmt.Println("all documents decode strictly")
}
