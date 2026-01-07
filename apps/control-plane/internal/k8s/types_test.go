package k8s

import (
	"encoding/json"
	"testing"
)

func TestSandboxClaimIsBound(t *testing.T) {
	tests := []struct {
		name     string
		claim    *SandboxClaim
		expected bool
	}{
		{
			name:     "nil sandbox reference",
			claim:    &SandboxClaim{},
			expected: false,
		},
		{
			name: "empty sandbox name",
			claim: &SandboxClaim{
				Status: SandboxClaimStatus{
					Sandbox: &SandboxReference{Name: ""},
				},
			},
			expected: false,
		},
		{
			name: "bound with sandbox name",
			claim: &SandboxClaim{
				Status: SandboxClaimStatus{
					Sandbox: &SandboxReference{Name: "sandbox-abc123"},
				},
			},
			expected: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := tt.claim.IsBound()
			if result != tt.expected {
				t.Errorf("IsBound() = %v, want %v", result, tt.expected)
			}
		})
	}
}

func TestSandboxClaimGetBoundSandboxName(t *testing.T) {
	tests := []struct {
		name     string
		claim    *SandboxClaim
		expected string
	}{
		{
			name:     "nil sandbox reference",
			claim:    &SandboxClaim{},
			expected: "",
		},
		{
			name: "has sandbox name",
			claim: &SandboxClaim{
				Status: SandboxClaimStatus{
					Sandbox: &SandboxReference{Name: "sandbox-xyz789"},
				},
			},
			expected: "sandbox-xyz789",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := tt.claim.GetBoundSandboxName()
			if result != tt.expected {
				t.Errorf("GetBoundSandboxName() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestSandboxClaimGetError(t *testing.T) {
	tests := []struct {
		name     string
		claim    *SandboxClaim
		expected string
	}{
		{
			name:     "no conditions",
			claim:    &SandboxClaim{},
			expected: "",
		},
		{
			name: "ready condition true",
			claim: &SandboxClaim{
				Status: SandboxClaimStatus{
					Conditions: []SandboxCondition{
						{Type: "Ready", Status: "True"},
					},
				},
			},
			expected: "",
		},
		{
			name: "ready condition false with message",
			claim: &SandboxClaim{
				Status: SandboxClaimStatus{
					Conditions: []SandboxCondition{
						{Type: "Ready", Status: "False", Message: "Pool exhausted"},
					},
				},
			},
			expected: "Pool exhausted",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := tt.claim.GetError()
			if result != tt.expected {
				t.Errorf("GetError() = %q, want %q", result, tt.expected)
			}
		})
	}
}

func TestSandboxClaimJSONMarshaling(t *testing.T) {
	claim := &SandboxClaim{
		Spec: SandboxClaimSpec{
			SandboxTemplateRef: SandboxTemplateRef{
				Name: "netclode-agent",
			},
		},
		Status: SandboxClaimStatus{
			Sandbox: &SandboxReference{Name: "sandbox-test"},
		},
	}

	data, err := json.Marshal(claim)
	if err != nil {
		t.Fatalf("Failed to marshal: %v", err)
	}

	var unmarshaled SandboxClaim
	if err := json.Unmarshal(data, &unmarshaled); err != nil {
		t.Fatalf("Failed to unmarshal: %v", err)
	}

	if unmarshaled.Spec.SandboxTemplateRef.Name != "netclode-agent" {
		t.Errorf("SandboxTemplateRef.Name = %q, want %q", unmarshaled.Spec.SandboxTemplateRef.Name, "netclode-agent")
	}

	if unmarshaled.Status.Sandbox == nil || unmarshaled.Status.Sandbox.Name != "sandbox-test" {
		t.Errorf("Status.Sandbox.Name unexpected value")
	}
}

func TestSandboxReferenceJSONField(t *testing.T) {
	// The CRD uses capital "Name" field
	jsonStr := `{"Name": "my-sandbox"}`

	var ref SandboxReference
	if err := json.Unmarshal([]byte(jsonStr), &ref); err != nil {
		t.Fatalf("Failed to unmarshal: %v", err)
	}

	if ref.Name != "my-sandbox" {
		t.Errorf("Name = %q, want %q", ref.Name, "my-sandbox")
	}
}
