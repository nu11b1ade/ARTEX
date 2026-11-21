package webfetch

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	actool "github.com/Autumn-27/norma/tool"
)

func TestCONNECTKeepsLogicalRequestIdentity(t *testing.T) {
	var proxyUAs, targetUAs []string
	var mu sync.Mutex
	target := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		targetUAs = append(targetUAs, r.UserAgent())
		mu.Unlock()
		fmt.Fprint(w, "ok")
	}))
	defer target.Close()
	proxy := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodConnect {
			t.Errorf("proxy method = %q", r.Method)
		}
		mu.Lock()
		proxyUAs = append(proxyUAs, r.UserAgent())
		mu.Unlock()
		// Force the existing direct fallback with a deterministic proxy EOF.
		conn, _, err := w.(http.Hijacker).Hijack()
		if err != nil {
			t.Error(err)
			return
		}
		conn.Close()
	}))
	defer proxy.Close()
	tool := New(actool.WebFetchConfig{Proxy: proxy.URL, InsecureTLS: true})
	for _, ua := range []string{"First-UA/1.0", "Second-UA/1.0"} {
		t.Setenv("ARTEX_HTTP_USER_AGENT", ua)
		result := callFetch(t, tool, target.URL, false)
		if result.IsError {
			t.Fatalf("fetch: %s", result.Flatten())
		}
	}
	mu.Lock()
	defer mu.Unlock()
	for name, got := range map[string][]string{"CONNECT": proxyUAs, "target": targetUAs} {
		if strings.Join(got, ",") != "First-UA/1.0,Second-UA/1.0" {
			t.Errorf("%s identities = %v", name, got)
		}
	}
}

func TestCrossOriginRedirectPreservesBrowserPolicy(t *testing.T) {
	const ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"
	t.Setenv("ARTEX_HTTP_USER_AGENT", ua)
	var origin string
	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for name, want := range map[string]string{
			"User-Agent":         ua,
			"Referer":            origin + "/",
			"Accept-Language":    "en-US,en;q=0.9",
			"Sec-Fetch-Site":     "none",
			"Sec-CH-UA-Platform": `"Windows"`,
		} {
			if got := r.Header.Get(name); got != want {
				t.Errorf("%s = %q, want %q", name, got, want)
			}
		}
		if !strings.Contains(r.Header.Get("Accept"), "text/html") {
			t.Error("navigation Accept missing")
		}
		if !strings.Contains(r.Header.Get("Sec-CH-UA"), `v="157"`) {
			t.Error("client hints do not match selected UA")
		}
		fmt.Fprint(w, "ok")
	}))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, target.URL, http.StatusFound)
	}))
	defer source.Close()
	origin = source.URL
	result := callFetch(t, New(actool.WebFetchConfig{}), source.URL+"/private?token=must-not-leak", false)
	if result.IsError {
		t.Fatalf("fetch: %s", result.Flatten())
	}
}
