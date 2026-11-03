package netprofile

import (
	"net/http"
	"testing"
)

func TestApplyFillsBrowserDefaults(t *testing.T) {
	req, _ := http.NewRequest(http.MethodPost, "https://example.test/api", nil)
	Apply(req)

	for name, want := range map[string]string{
		"User-Agent":      UserAgent,
		"Accept":          acceptAny,
		"Accept-Language": AcceptLanguage,
	} {
		if got := req.Header.Get(name); got != want {
			t.Fatalf("%s = %q, want %q", name, got, want)
		}
	}
}

func TestApplyPreservesCallerHeaders(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "https://example.test/api", nil)
	req.Header.Set("User-Agent", "custom-agent")
	req.Header.Set("Accept", "application/json")
	Apply(req)

	if got := req.Header.Get("User-Agent"); got != "custom-agent" {
		t.Fatalf("User-Agent overwritten: %q", got)
	}
	if got := req.Header.Get("Accept"); got != "application/json" {
		t.Fatalf("Accept overwritten: %q", got)
	}
	if got := req.Header.Get("Accept-Language"); got != AcceptLanguage {
		t.Fatalf("Accept-Language = %q", got)
	}
}

func TestNavigateAddsFetchMetadata(t *testing.T) {
	req, _ := http.NewRequest(http.MethodGet, "https://example.test/", nil)
	Navigate(req)

	for name, want := range map[string]string{
		"User-Agent":                UserAgent,
		"Accept":                    acceptHTML,
		"Accept-Language":           AcceptLanguage,
		"Upgrade-Insecure-Requests": "1",
		"Sec-Fetch-Site":            "none",
		"Sec-Fetch-Mode":            "navigate",
		"Sec-Fetch-User":            "?1",
		"Sec-Fetch-Dest":            "document",
	} {
		if got := req.Header.Get(name); got != want {
			t.Fatalf("%s = %q, want %q", name, got, want)
		}
	}
}
