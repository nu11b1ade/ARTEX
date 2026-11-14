// Package netprofile 统一 ARTEX 自身发出的 HTTP 请求所携带的浏览器特征。
//
// 平台主动探测目标（enrich、出口探测、自定义 HTTP 工具）以及访问基础设施
// （自更新）时，请求头里不应出现 artex 之类的工具标识：那会让目标/WAF
// 一眼识别出扫描器，也违背了普通用户流量的形态。所有出站点都从这里取
// 同一套 UA / Accept / Accept-Language，避免各写一份后再次漂移。
//
// 这里只负责 HTTP 头，不改变 TLS 指纹；带 Keep-Alive 的连接复用、HTTP/2
// 等仍由 net/http 的 Transport 决定。
package netprofile

import "net/http"

// UserAgent 是 ARTEX 主动请求时使用的桌面 Chrome UA。
//
// 刻意不带产品名、版本号或构建信息。容器默认运行在 Linux 上，因此使用
// Linux 桌面 UA，避免 UA 与浏览器实际平台明显冲突。Chrome 大版本更新后
// 可以整体替换此常量（保持格式为 Chrome/<major>.0.0.0）。
const UserAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"

const (
	// acceptHTML 与 Chrome 地址栏直接打开页面时发送的 Accept 一致。
	acceptHTML = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7"
	// acceptAny 与浏览器 fetch/XHR 默认的 Accept 一致。
	acceptAny = "*/*"
	// AcceptLanguage 是 ARTEX 主动请求统一使用的语言标记。
	AcceptLanguage = "en-US,en;q=0.9"
)

// Apply 为请求补齐浏览器默认头；调用方已经设置的值一律保留。
//
// 适用于 API 形态的请求（POST JSON、自定义 HTTP 工具等）。它只补
// User-Agent / Accept / Accept-Language，不伪造 Sec-Fetch-*——这些字段
// 依赖真实页面的 origin，凭空填写反而更像自动化客户端。
func Apply(req *http.Request) {
	setIfEmpty(req, "User-Agent", UserAgent)
	setIfEmpty(req, "Accept", acceptAny)
	setIfEmpty(req, "Accept-Language", AcceptLanguage)
}

// Navigate 在 Apply 的基础上补齐浏览器“地址栏直接打开页面”时的
// Fetch Metadata。用于对站点的探活/爬取请求（enrich、出口 IP 探测、
// Release 资产下载等），这类请求本来就是顶层导航形态。
func Navigate(req *http.Request) {
	setIfEmpty(req, "User-Agent", UserAgent)
	setIfEmpty(req, "Accept", acceptHTML)
	setIfEmpty(req, "Accept-Language", AcceptLanguage)
	setIfEmpty(req, "Upgrade-Insecure-Requests", "1")
	setIfEmpty(req, "Sec-Fetch-Site", "none")
	setIfEmpty(req, "Sec-Fetch-Mode", "navigate")
	setIfEmpty(req, "Sec-Fetch-User", "?1")
	setIfEmpty(req, "Sec-Fetch-Dest", "document")
}

func setIfEmpty(req *http.Request, name, value string) {
	if req.Header.Get(name) == "" {
		req.Header.Set(name, value)
	}
}
