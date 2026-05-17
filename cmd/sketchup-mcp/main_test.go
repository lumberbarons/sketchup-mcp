package main

import (
	"strings"
	"testing"
)

func TestBuildInstructions_QuietWhenReachable(t *testing.T) {
	got := buildInstructions("localhost", 9876, true)
	if strings.Contains(got, "NOTE") {
		t.Fatalf("reachable: instructions should not include advisory, got %q", got)
	}
	if got == "" {
		t.Fatal("reachable: instructions must not be empty")
	}
}

func TestBuildInstructions_AdvisesWhenUnreachable(t *testing.T) {
	got := buildInstructions("localhost", 9876, false)
	for _, want := range []string{"not reachable", "localhost:9876", "Start Server"} {
		if !strings.Contains(got, want) {
			t.Errorf("unreachable advisory missing %q in:\n%s", want, got)
		}
	}
}
