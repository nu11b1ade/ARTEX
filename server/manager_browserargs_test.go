package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Autumn-27/artex/netprofile"
)

func TestEnsureBrowserMCPArgsAddsSandboxFlags(t *testing.T) {
	got := ensureBrowserMCPArgs([]string{"@playwright/mcp", "--headless"}, false)

	for _, want := range []string{"--headless", "--no-sandbox"} {
		found := false
		for _, arg := range got {
			if arg == want {
				found = true
				break
			}
		}
		if !found {
			t.Fatalf("missing %s in %q", want, got)
		}
	}
	// The UA must travel through env, never argv: the web editor joins args with
	// spaces and splits them on whitespace, which would truncate the UA.
	for _, arg := range got {
		if arg == "--user-agent" || strings.HasPrefix(arg, "--user-agent=") {
			t.Fatalf("user agent must not be in argv: %q", got)
		}
	}
}

func TestEnsureBrowserMCPClientProfileAddsEnv(t *testing.T) {
	dir := t.TempDir()
	env := ensureBrowserMCPClientProfile(dir, []string{"@playwright/mcp", "--headless"}, nil)

	if got := env["PLAYWRIGHT_MCP_USER_AGENT"]; got != netprofile.UserAgent {
		t.Fatalf("PLAYWRIGHT_MCP_USER_AGENT = %q, want %q", got, netprofile.UserAgent)
	}
	cfgPath := env["PLAYWRIGHT_MCP_CONFIG"]
	if want := filepath.Join(dir, browserMCPConfigFile); cfgPath != want {
		t.Fatalf("PLAYWRIGHT_MCP_CONFIG = %q, want %q", cfgPath, want)
	}
	raw, err := os.ReadFile(cfgPath)
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	var cfg struct {
		Browser struct {
			ContextOptions struct {
				Locale           string            `json:"locale"`
				ExtraHTTPHeaders map[string]string `json:"extraHTTPHeaders"`
			} `json:"contextOptions"`
		} `json:"browser"`
	}
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("parse config: %v", err)
	}
	if cfg.Browser.ContextOptions.Locale != "en-US" {
		t.Fatalf("locale = %q", cfg.Browser.ContextOptions.Locale)
	}
	if got := cfg.Browser.ContextOptions.ExtraHTTPHeaders["Accept-Language"]; got != netprofile.AcceptLanguage {
		t.Fatalf("Accept-Language = %q, want %q", got, netprofile.AcceptLanguage)
	}
}

func TestEnsureBrowserMCPClientProfilePreservesUserEnv(t *testing.T) {
	dir := t.TempDir()
	env := map[string]string{
		"PLAYWRIGHT_MCP_USER_AGENT": "custom-env-ua",
		"PLAYWRIGHT_MCP_CONFIG":     "/custom/config.json",
	}
	got := ensureBrowserMCPClientProfile(dir, []string{"@playwright/mcp"}, env)

	if got["PLAYWRIGHT_MCP_USER_AGENT"] != "custom-env-ua" {
		t.Fatalf("user agent overwritten: %q", got["PLAYWRIGHT_MCP_USER_AGENT"])
	}
	if got["PLAYWRIGHT_MCP_CONFIG"] != "/custom/config.json" {
		t.Fatalf("config path overwritten: %q", got["PLAYWRIGHT_MCP_CONFIG"])
	}
}

func TestEnsureBrowserMCPClientProfileRespectsArgFlags(t *testing.T) {
	dir := t.TempDir()
	got := ensureBrowserMCPClientProfile(dir, []string{"--user-agent", "custom-arg"}, nil)

	if _, ok := got["PLAYWRIGHT_MCP_USER_AGENT"]; ok {
		t.Fatalf("env UA must not be added when argv sets one: %v", got)
	}
	if got["PLAYWRIGHT_MCP_CONFIG"] == "" {
		t.Fatalf("config env missing: %v", got)
	}
}

func TestEnsureBrowserMCPClientProfileRewritesGeneratedConfig(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, browserMCPConfigFile)
	if err := os.WriteFile(path, []byte("stale"), 0o600); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"PLAYWRIGHT_MCP_CONFIG": path}
	got := ensureBrowserMCPClientProfile(dir, nil, env)

	raw, err := os.ReadFile(got["PLAYWRIGHT_MCP_CONFIG"])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"locale": "en-US"`) {
		t.Fatalf("generated config was not refreshed: %s", raw)
	}
}
