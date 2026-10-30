package provider

import (
	"net"

	"github.com/yetone/magpie/internal/netproxy"
)

// SkipsRedaction says requests to p go unmasked: the user set Unredacted
// ("Send requests unmasked") and p has an address. It is the user's word
// whatever the address (AcMilan on Discord: the user decides for each
// provider); the editor cautions when an address isn't on this machine or
// the local network (LocalHost), and nothing here looks one up. A
// signed-in account, a plugin's provider and another magpie are always
// masked: each reaches a vendor.
func (p Provider) SkipsRedaction() bool {
	if !p.Unredacted || p.Account != nil || p.IsRemoteMagpie() {
		return false
	}
	for _, b := range []string{p.Chat, p.Responses, p.Anthropic, p.Gemini, p.Decide} {
		if b != "" {
			return true
		}
	}
	return false
}

// LocalHost says host is on this machine or the local network: localhost,
// a .local name, a loopback, private or link-local IP, or a name every
// address of which is one (netproxy.LocalName, looked up now and kept a
// minute; one that doesn't resolve isn't). Only the editor's caution asks
// it (/api/local-hosts), never a request.
func LocalHost(host string) bool {
	if local(host) {
		return true
	}
	if ip := net.ParseIP(host); ip != nil {
		return netproxy.LocalIP(ip)
	}
	return netproxy.LocalName(host)
}
