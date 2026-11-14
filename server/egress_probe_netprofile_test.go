package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Autumn-27/artex/netprofile"
)

func TestEgressProbePreservesBrowserHeaders(t *testing.T) {
	for _, proxied := range []bool{false, true} {
		name := "direct"
		if proxied {
			name = "proxy"
		}
		t.Run(name, func(t *testing.T) {
			headers := make(chan http.Header, 1)
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				headers <- r.Header.Clone()
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"ip":"203.0.113.7"}`))
			}))
			defer srv.Close()

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if proxied {
				res := probeEgress(ctx, srv.URL, "", []string{"http://egress.example.test/ip"}, time.Second)
				if !res.OK || res.ExitIP != "203.0.113.7" {
					t.Fatalf("proxy probe failed: %+v", res)
				}
			} else if ip, err := probeOne(ctx, srv.Client(), srv.URL); err != nil || ip != "203.0.113.7" {
				t.Fatalf("direct probe: ip=%q err=%v", ip, err)
			}

			select {
			case got := <-headers:
				if ua := got.Get("User-Agent"); ua != netprofile.UserAgent {
					t.Errorf("User-Agent = %q, want browser profile %q", ua, netprofile.UserAgent)
				}
				if language := got.Get("Accept-Language"); language != netprofile.AcceptLanguage {
					t.Errorf("Accept-Language = %q, want %q", language, netprofile.AcceptLanguage)
				}
			case <-ctx.Done():
				t.Fatal("probe server did not receive a request")
			}
		})
	}
}
