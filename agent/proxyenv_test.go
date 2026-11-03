package agent

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Autumn-27/artex/netprofile"
)

func envValue(env []string, prefix string) string {
	for _, e := range env {
		if strings.HasPrefix(e, prefix) {
			return strings.TrimPrefix(e, prefix)
		}
	}
	return ""
}

func TestProxyEnvDirectStillSetsClientProfile(t *testing.T) {
	env := proxyEnv("", "")
	home := envValue(env, "CURL_HOME=")
	if home == "" {
		t.Fatalf("proxyEnv(\"\", \"\") missing CURL_HOME: %v", env)
	}
	for _, name := range []string{".curlrc", "_curlrc"} {
		b, err := os.ReadFile(filepath.Join(home, name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		if !strings.Contains(string(b), netprofile.UserAgent) {
			t.Fatalf("%s does not contain the browser UA: %q", name, b)
		}
		if !strings.Contains(string(b), netprofile.AcceptLanguage) {
			t.Fatalf("%s does not contain Accept-Language: %q", name, b)
		}
	}
	wgetrc := envValue(env, "WGETRC=")
	if wgetrc == "" {
		t.Fatalf("proxyEnv missing WGETRC: %v", env)
	}
	if b, err := os.ReadFile(wgetrc); err != nil || !strings.Contains(string(b), netprofile.UserAgent) || !strings.Contains(string(b), netprofile.AcceptLanguage) {
		t.Fatalf("wgetrc = %q, err = %v", b, err)
	}
	for _, e := range env {
		if strings.HasPrefix(e, "HTTP_PROXY=") || strings.HasPrefix(e, "ALL_PROXY=") {
			t.Fatalf("direct env must not contain proxy vars: %v", env)
		}
	}
}

func TestProxyEnvSetsAllProxyForSocks5(t *testing.T) {
	// Capture-off egress path: a socks5 proxy, no MITM CA. ALL_PROXY must be set
	// (curl reads socks5 only from there), and no CA vars should appear.
	env := proxyEnv("socks5://10.0.0.1:1080", "")
	has := func(prefix string) bool {
		for _, e := range env {
			if strings.HasPrefix(e, prefix) {
				return true
			}
		}
		return false
	}
	for _, want := range []string{"HTTP_PROXY=", "HTTPS_PROXY=", "ALL_PROXY=", "all_proxy="} {
		if !has(want) {
			t.Errorf("proxyEnv missing %s: %v", want, env)
		}
	}
	if has("SSL_CERT_FILE=") || has("CURL_CA_BUNDLE=") {
		t.Errorf("proxyEnv without CA must not inject CA vars: %v", env)
	}
}

func TestProxyEnvInjectsCAWhenRecording(t *testing.T) {
	env := proxyEnv("http://127.0.0.1:8788", "/data/ca.pem")
	has := func(prefix string) bool {
		for _, e := range env {
			if strings.HasPrefix(e, prefix) {
				return true
			}
		}
		return false
	}
	for _, want := range []string{"SSL_CERT_FILE=", "CURL_CA_BUNDLE=", "REQUESTS_CA_BUNDLE=", "NODE_EXTRA_CA_CERTS="} {
		if !has(want) {
			t.Errorf("proxyEnv with CA missing %s: %v", want, env)
		}
	}
}
