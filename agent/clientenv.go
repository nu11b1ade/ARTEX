package agent

import (
	"os"
	"path/filepath"
	"sync"

	"github.com/Autumn-27/artex/netprofile"
)

var (
	shellClientOnce sync.Once
	shellClientDir  string
	shellClientErr  error
)

// shellClientEnv points the shell tools' default HTTP clients at a private
// config directory. Without it every `curl`/`wget` an agent runs announces
// itself as "curl/x.y" / "Wget/x.y", which is a scanner tell even when the
// command itself is harmless.
//
// The config sets only the User-Agent. An explicit -A/--user-agent or
// -H "User-Agent: ..." on the command line still wins (curl replaces its
// generated header; wget's command-line option overrides the rc file), so an
// agent replaying headers observed on the target is not affected and no
// duplicate User-Agent is emitted.
func shellClientEnv() []string {
	shellClientOnce.Do(func() {
		dir, err := os.MkdirTemp("", "artex-http-client-")
		if err != nil {
			shellClientErr = err
			return
		}
		// curl/wget 都只是追加自定义头，不会替换调用方显式传入的同名头；
		// 若 agent 回放目标流量时自带 Accept-Language，可能出现重复头。
		// 常见路径（没有可参考流量）下，补齐语言标记更接近普通浏览器。
		curlrc := "# ARTEX: default browser headers; explicit -A/-H overrides User-Agent.\n" +
			"user-agent = \"" + netprofile.UserAgent + "\"\n" +
			"header = \"Accept-Language: " + netprofile.AcceptLanguage + "\"\n"
		wgetrc := "user_agent = " + netprofile.UserAgent + "\n" +
			"header = Accept-Language: " + netprofile.AcceptLanguage + "\n"
		// curl uses .curlrc on Unix and _curlrc on Windows; write both so the
		// same CURL_HOME works on every platform ARTEX runs on.
		files := map[string]string{
			".curlrc": curlrc,
			"_curlrc": curlrc,
			"wgetrc":  wgetrc,
		}
		for name, content := range files {
			if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
				shellClientErr = err
				_ = os.RemoveAll(dir)
				return
			}
		}
		shellClientDir = dir
	})
	if shellClientErr != nil || shellClientDir == "" {
		return nil
	}
	return []string{
		"CURL_HOME=" + shellClientDir,
		"WGETRC=" + filepath.Join(shellClientDir, "wgetrc"),
	}
}
