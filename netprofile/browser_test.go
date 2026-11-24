package netprofile

import (
	"net/http"
	"net/url"
	"strings"
	"testing"
)

func TestBrowserHintsFollowSelectedSample(t *testing.T) {
	for _, tc := range []struct{ ua, platform string }{
		{UserAgent, `"Linux"`},
		{"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36", `"macOS"`},
		{"Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:159.0) Gecko/20100101 Firefox/159.0", ""},
		{"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.1 Safari/605.1.15", ""},
	} {
		req, _ := http.NewRequest(http.MethodGet, "https://example.test/", nil)
		req.Header.Set("User-Agent", tc.ua)
		BrowserNavigate(req)
		if got := req.Header.Get("Sec-CH-UA-Platform"); got != tc.platform {
			t.Errorf("platform = %q, want %q for %q", got, tc.platform, tc.ua)
		}
		if tc.platform == "" && req.Header.Get("Sec-CH-UA") != "" {
			t.Errorf("Chromium hints sent with non-Chromium UA %q", tc.ua)
		}
	}
}

func TestBrowserRedirectDowngradeWithholdsIdentityMetadata(t *testing.T) {
	start, _ := http.NewRequest(http.MethodGet, "https://source.test/private?token=secret", nil)
	start.Header.Set("User-Agent", UserAgent)
	BrowserNavigate(start)
	next := start.Clone(start.Context())
	next.URL, _ = url.Parse("http://other.test/")
	next.Header.Set("Referer", start.URL.String())
	if err := BrowserCheckRedirect(next, []*http.Request{start}); err != nil {
		t.Fatal(err)
	}
	for key := range next.Header {
		if key == "Referer" || strings.HasPrefix(key, "Sec-Ch-") || strings.HasPrefix(key, "Sec-Fetch-") {
			t.Errorf("downgrade retained %s", key)
		}
	}
}
