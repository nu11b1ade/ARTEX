// Browser navigation and redirect policy adapted from nu11b1ade/Norma v0.4.3.
package netprofile

import (
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"golang.org/x/net/publicsuffix"
)

// BrowserNavigate retains the SDK's secure-context headers while letting the
// platform select a UA. Client hints must describe that selected sample.
func BrowserNavigate(req *http.Request) {
	Navigate(req)
	trustworthy := potentiallyTrustworthy(req.URL)
	setClientHints(req.Header, trustworthy)
	if !trustworthy {
		clearFetchMetadata(req.Header)
	}
}

var chromiumVersion = regexp.MustCompile(`Chrome/([0-9]+)\.`)

func setClientHints(h http.Header, trustworthy bool) {
	for _, name := range []string{"Sec-CH-UA", "Sec-CH-UA-Mobile", "Sec-CH-UA-Platform"} {
		h.Del(name)
	}
	match := chromiumVersion.FindStringSubmatch(h.Get("User-Agent"))
	if !trustworthy || len(match) != 2 {
		return
	}
	ua := h.Get("User-Agent")
	platform := "Linux"
	switch {
	case strings.Contains(ua, "Windows NT"):
		platform = "Windows"
	case strings.Contains(ua, "Macintosh"):
		platform = "macOS"
	case !strings.Contains(ua, "X11; Linux"):
		// Unknown/custom Chrome-like UA: do not invent a desktop platform.
		return
	}
	brand := "Google Chrome"
	if strings.Contains(ua, "Edg/") {
		brand = "Microsoft Edge"
	}
	h.Set("Sec-CH-UA", fmt.Sprintf(`"Chromium";v="%s", "Not_A Brand";v="24", "%s";v="%s"`, match[1], brand, match[1]))
	h.Set("Sec-CH-UA-Mobile", "?0")
	h.Set("Sec-CH-UA-Platform", fmt.Sprintf("%q", platform))
}

func setFetchMetadata(h http.Header, site string) {
	h.Set("Sec-Fetch-Site", site)
	h.Set("Sec-Fetch-Mode", "navigate")
	h.Set("Sec-Fetch-User", "?1")
	h.Set("Sec-Fetch-Dest", "document")
}

func clearFetchMetadata(h http.Header) {
	for _, name := range []string{"Sec-Fetch-Site", "Sec-Fetch-Mode", "Sec-Fetch-User", "Sec-Fetch-Dest"} {
		h.Del(name)
	}
}

// BrowserCheckRedirect applies Chrome's redirect behavior to every hop:
//   - strict-origin-when-cross-origin referrer policy (net/http's default
//     sends the full previous URL on every hop);
//   - client hints and Fetch Metadata are present only on potentially
//     trustworthy targets;
//   - Sec-Fetch-Site is recomputed over the whole redirect chain.
//
// It intentionally leaves a typed navigation's Sec-Fetch-Site: none alone;
// the Fetch Metadata algorithm preserves that value across redirects.
func BrowserCheckRedirect(req *http.Request, via []*http.Request) error {
	// Match net/http's built-in redirect limit.
	if len(via) >= 10 {
		return errors.New("stopped after 10 redirects")
	}
	if len(via) == 0 {
		return nil
	}
	prev := via[len(via)-1].URL
	req.Header.Del("Referer")
	trustworthy := potentiallyTrustworthy(req.URL)
	setClientHints(req.Header, trustworthy)
	if trustworthy {
		setFetchMetadata(req.Header, redirectFetchSite(via, req.URL))
	} else {
		clearFetchMetadata(req.Header)
	}
	// net/http rewrites 301/302/303 redirects to GET but copies the original
	// request's headers. A browser navigation GET carries neither of these.
	if req.Method == http.MethodGet || req.Method == http.MethodHead {
		req.Header.Del("Origin")
		req.Header.Del("Content-Type")
	}
	switch {
	case prev.Scheme == "https" && req.URL.Scheme != "https":
		// HTTPS -> HTTP downgrade: the browser withholds the referrer entirely.
	case sameOrigin(prev, req.URL):
		u := *prev
		u.User = nil
		u.Fragment = ""
		u.RawFragment = ""
		req.Header.Set("Referer", u.String())
	default:
		req.Header.Set("Referer", prev.Scheme+"://"+strings.ToLower(prev.Host)+"/")
	}
	return nil
}

// redirectFetchSite implements Fetch Metadata's set-site algorithm over the
// full redirect chain. The initiator's site mode comes from the first request:
// an explicitly user-initiated navigation ("none") stays none; otherwise the
// value is recomputed from every URL in the chain.
func redirectFetchSite(via []*http.Request, target *url.URL) string {
	init := via[0]
	switch init.Header.Get("Sec-Fetch-Site") {
	case "none":
		return "none"
	case "":
		if init.Header.Get("Origin") == "" {
			// The initial URL was not potentially trustworthy, so Fetch
			// Metadata was omitted; no Origin identifies the typed-URL profile.
			return "none"
		}
	}
	origin := init.URL
	if raw := init.Header.Get("Origin"); raw != "" {
		if u, err := url.Parse(raw); err == nil && u.Scheme != "" && u.Host != "" {
			origin = u
		}
	}
	return redirectSite(origin, via, target)
}

// redirectSite walks the full URL list, per Fetch Metadata's set-site
// algorithm. The value can only degrade: same-origin -> same-site ->
// cross-site, and a cross-site hop ends the walk permanently.
func redirectSite(origin *url.URL, via []*http.Request, target *url.URL) string {
	site := "same-origin"
	for _, r := range via {
		if sameOrigin(r.URL, origin) {
			continue
		}
		site = "cross-site"
		if !sameSite(origin, r.URL) {
			return site
		}
		site = "same-site"
	}
	if !sameOrigin(target, origin) {
		site = "cross-site"
		if sameSite(origin, target) {
			site = "same-site"
		}
	}
	return site
}

func sameOrigin(a, b *url.URL) bool {
	return strings.EqualFold(a.Scheme, b.Scheme) &&
		strings.EqualFold(a.Hostname(), b.Hostname()) &&
		originPort(a) == originPort(b)
}

// sameSite follows HTML's schemeful same-site rule: the schemes must match and
// the hosts' registrable domains must be equal. Ports are ignored.
func sameSite(a, b *url.URL) bool {
	if !strings.EqualFold(a.Scheme, b.Scheme) {
		return false
	}
	ah, bh := siteHost(a), siteHost(b)
	return ah != "" && strings.EqualFold(ah, bh)
}

// siteHost returns the host's registrable domain, or the host itself when it
// has none (IP addresses, localhost), per HTML's "obtain a site".
func siteHost(u *url.URL) string {
	host := strings.ToLower(u.Hostname())
	if d, err := publicsuffix.EffectiveTLDPlusOne(host); err == nil {
		return d
	}
	return host
}

func potentiallyTrustworthyURL(raw string) bool {
	u, err := url.Parse(raw)
	return err == nil && potentiallyTrustworthy(u)
}

// potentiallyTrustworthy reports whether a browser treats u as a secure
// context for Client Hints and Fetch Metadata: HTTPS, or a loopback origin.
func potentiallyTrustworthy(u *url.URL) bool {
	if u.Scheme == "https" {
		return true
	}
	if u.Scheme != "http" {
		return false
	}
	host := strings.ToLower(u.Hostname())
	if host == "localhost" || strings.HasSuffix(host, ".localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func originPort(u *url.URL) string {
	if p := u.Port(); p != "" {
		return p
	}
	switch strings.ToLower(u.Scheme) {
	case "http":
		return "80"
	case "https":
		return "443"
	}
	return ""
}
