#!/bin/bash
# Deterministic source transformations applied only to scratch build copies of pinned anylinuxfs.
# The vendored submodule remains byte-for-byte at ANYLINUXFS_COMMIT.

patch_anylinuxfs_runtime_alpine() {
  local build_root="$1"
  python3 - "$build_root" "$ALPINE_RUNTIME_REF" "$ALPINE_RUNTIME_BASE_DIR" "$ALPINE_RUNTIME_VERSION" <<'PYEOF'
from pathlib import Path
import sys

root = Path(sys.argv[1])
ref, base_dir, version = sys.argv[2:]

settings = root / "anylinuxfs/src/settings.rs"
text = settings.read_text()
replacements = {
    'base_dir: "alpine".into(),': f'base_dir: "{base_dir}".into(),',
    'docker_ref: Some("alpine:latest".into()),': f'docker_ref: Some("{ref}".into()),',
    '''pub struct NetworkPrefs {
    pub helper: Option<NetHelper>,
    #[serde(default)]
    pub vmnet_pool: Option<Ipv4Net>,
    #[serde(default)]
    pub vmnet_offloading: Option<VmnetOffloading>,
}''': '''pub struct NetworkPrefs {
    pub helper: Option<NetHelper>,
    #[serde(default)]
    pub vmnet_pool: Option<Ipv4Net>,
    #[serde(default)]
    pub vmnet_offloading: Option<VmnetOffloading>,
    #[serde(default)]
    pub proxy: Option<String>,
}''',
    '''impl NetworkPrefs {
    fn merge_with(&self, other: &NetworkPrefs) -> NetworkPrefs {
        NetworkPrefs {
            helper: other.helper.or(self.helper),
            vmnet_pool: other.vmnet_pool.clone().or(self.vmnet_pool.clone()),
            vmnet_offloading: other.vmnet_offloading.or(self.vmnet_offloading),
        }
    }
}''': '''impl NetworkPrefs {
    fn merge_with(&self, other: &NetworkPrefs) -> NetworkPrefs {
        NetworkPrefs {
            helper: other.helper.or(self.helper),
            vmnet_pool: other.vmnet_pool.clone().or(self.vmnet_pool.clone()),
            vmnet_offloading: other.vmnet_offloading.or(self.vmnet_offloading),
            proxy: other.proxy.clone().or_else(|| self.proxy.clone()),
        }
    }
}''',
}
for old, new in replacements.items():
    if text.count(old) != 1:
        raise SystemExit(f"build-all: HARD-STOP — expected exactly one marker in {settings}: {old}")
    text = text.replace(old, new, 1)
settings.write_text(text)

vm_image = root / "anylinuxfs/src/vm_image.rs"
text = vm_image.read_text()
old = 'src.docker_ref.as_deref().unwrap_or("alpine:latest")'
new = f'src.docker_ref.as_deref().unwrap_or("{ref}")'
if text.count(old) != 1:
    raise SystemExit(f"build-all: HARD-STOP — expected exactly one fallback marker in {vm_image}")
text = text.replace(old, new, 1)

old_script_proxy = '''        if let Some(script) = src.setup_script.as_deref() {
            init_rootfs_cmd.args(&["-setup-script", script]);
        }'''
new_script_proxy = '''        if let Some(script) = src.setup_script.as_deref() {
            init_rootfs_cmd.args(&["-setup-script", script]);
        }
        use crate::settings::Preferences;
        let env_proxy = std::env::var("NTFSMAC_PROXY").ok()
            .or_else(|| std::env::var("HTTP_PROXY").ok())
            .or_else(|| std::env::var("http_proxy").ok());
        let effective_proxy = config.preferences.user().network.proxy.as_deref().or(env_proxy.as_deref());
        if let Some(p) = effective_proxy {
            init_rootfs_cmd.args(&["-proxy", p]);
            init_rootfs_cmd.env("HTTP_PROXY", p);
            init_rootfs_cmd.env("HTTPS_PROXY", p);
            init_rootfs_cmd.env("http_proxy", p);
            init_rootfs_cmd.env("https_proxy", p);
        }'''
if text.count(old_script_proxy) != 1:
    raise SystemExit(f"build-all: HARD-STOP — expected exactly one setup-script marker in {vm_image}")
text = text.replace(old_script_proxy, new_script_proxy, 1)
vm_image.write_text(text)

main_rs = root / "anylinuxfs/src/main.rs"
text = main_rs.read_text()
old_apk_cmd = '''        let _inner = guard.upgrade()?;
        let vm_command = format!("{vm_prelude} && {apk_command}");'''
new_apk_cmd = '''        let _inner = guard.upgrade()?;
        let env_proxy = std::env::var("NTFSMAC_PROXY").ok()
            .or_else(|| std::env::var("HTTP_PROXY").ok())
            .or_else(|| std::env::var("http_proxy").ok());
        let proxy_export = config.preferences.user().network.proxy.as_deref().or(env_proxy.as_deref())
            .map(|p| format!("export http_proxy='{p}' https_proxy='{p}' HTTP_PROXY='{p}' HTTPS_PROXY='{p}' && "))
            .unwrap_or_default();
        let vm_command = format!("{vm_prelude} && {proxy_export}{apk_command}");'''
if text.count(old_apk_cmd) != 1:
    raise SystemExit(f"build-all: HARD-STOP — expected exactly one apk_command marker in {main_rs}")
text = text.replace(old_apk_cmd, new_apk_cmd, 1)
main_rs.write_text(text)

for config_name in ("anylinuxfs.toml", "anylinuxfs-linux.toml"):
    config = root / "etc" / config_name
    text = config.read_text()
    if text.count('base_dir = "alpine"') != 1 or text.count('docker_ref = "alpine:latest"') != 1:
        raise SystemExit(f"build-all: HARD-STOP — Alpine config markers drifted in {config}")
    text = text.replace('base_dir = "alpine"', f'base_dir = "{base_dir}"', 1)
    text = text.replace('docker_ref = "alpine:latest"', f'docker_ref = "{ref}"', 1)
    config.write_text(text)

version_path = root / "share/alpine/rootfs.ver"
version_path.write_text(version)

remaining = []
for path in (settings, vm_image, root / "etc/anylinuxfs.toml", root / "etc/anylinuxfs-linux.toml"):
    if "alpine:latest" in path.read_text():
        remaining.append(str(path))
if remaining:
    raise SystemExit("build-all: HARD-STOP — floating Alpine reference remains in " + ", ".join(remaining))
print(f"build-all: pinned runtime Alpine to {ref} in cache directory {base_dir}")
PYEOF
}

patch_init_rootfs_runtime_alpine() {
  local init_rootfs_dir="$1"
  python3 - "$init_rootfs_dir/main.go" "$ALPINE_RUNTIME_REF" <<'PYEOF'
from pathlib import Path
import sys

path = Path(sys.argv[1])
ref = sys.argv[2]
text = path.read_text()

markers = [
    ("// reference when no explicit base_dir is configured. Both the image name and\n// tag are included to avoid collisions (e.g. alpine:latest vs alpine:edge).\n",
     "// reference when no explicit base_dir is configured. Both the image name and\n// tag are included to avoid collisions between tagged or digest-pinned variants.\n"),
    ("\tImageName         string\n", "\tImageName         string\n\tSourceReference   string\n"),
    (
        "\t// Parse docker reference into image name and tag.\n\timageName := dockerRef\n\ttag := \"latest\"\n\tif idx := strings.LastIndex(dockerRef, \":\"); idx >= 0 {\n\t\timageName = dockerRef[:idx]\n\t\ttag = dockerRef[idx+1:]\n\t}\n",
        "\t// Keep the complete source reference (including an optional digest) for the registry.\n\t// The OCI layout still needs a local tag, derived deterministically from the digest.\n\timageName := dockerRef\n\ttag := \"runtime\"\n\tif at := strings.LastIndex(dockerRef, \"@\"); at >= 0 {\n\t\timageName = dockerRef[:at]\n\t\tdigest := strings.TrimPrefix(dockerRef[at+1:], \"sha256:\")\n\t\tif len(digest) < 12 {\n\t\t\tfmt.Println(\"Pinned Docker/OCI reference has an invalid digest\")\n\t\t\tos.Exit(1)\n\t\t}\n\t\ttag = \"pinned-\" + digest[:12]\n\t} else if idx := strings.LastIndex(dockerRef, \":\"); idx >= 0 {\n\t\timageName = dockerRef[:idx]\n\t\ttag = dockerRef[idx+1:]\n\t}\n",
    ),
    ("\t\tImageName:         imageName,\n", "\t\tImageName:         imageName,\n\t\tSourceReference:   dockerRef,\n"),
    ('docker.ParseReference(fmt.Sprintf("//%s:%s", cfg.ImageName, cfg.Tag))', 'docker.ParseReference("//" + cfg.SourceReference)'),
    ('flag.StringVar(&dockerRef, "docker-ref", "alpine:latest", "Docker/OCI image reference (e.g. alpine:latest, alpine:edge)")', f'flag.StringVar(&dockerRef, "docker-ref", "{ref}", "Digest-pinned Docker/OCI image reference")'),
    (
        '\t"net/http"\n',
        '\t"net/http"\n\t"net/url"\n',
    ),
    (
        '''type Preferences struct {
\tAlpine AlpineConfig `toml:"alpine"`
}

type AlpineConfig struct {
\tCustomPackages []string `toml:"custom_packages"`
}''',
        '''type NetworkConfig struct {
\tProxy string `toml:"proxy"`
}

type Preferences struct {
\tAlpine  AlpineConfig  `toml:"alpine"`
\tNetwork NetworkConfig `toml:"network"`
}

type AlpineConfig struct {
\tCustomPackages []string `toml:"custom_packages"`
\tProxy          string   `toml:"proxy"`
}

func resolveProxy(userStore string, cliProxy string) string {
\tif cliProxy != "" {
\t\treturn cliProxy
\t}
\tfor _, envKey := range []string{"NTFSMAC_PROXY", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"} {
\t\tif val := os.Getenv(envKey); val != "" {
\t\t\treturn val
\t\t}
\t}
\tconfigPath := filepath.Join(userStore, "config.toml")
\tif _, err := os.Stat(configPath); err == nil {
\t\tvar preferences Preferences
\t\tif _, err := toml.DecodeFile(configPath, &preferences); err == nil {
\t\t\tif preferences.Network.Proxy != "" {
\t\t\t\treturn preferences.Network.Proxy
\t\t\t}
\t\t\tif preferences.Alpine.Proxy != "" {
\t\t\t\treturn preferences.Alpine.Proxy
\t\t\t}
\t\t}
\t}
\treturn ""
}''',
    ),
    (
        '''\tvmSetupScriptPath := fmt.Sprintf("%s%s", cfg.RootfsPath, cfg.VmSetupScriptPath)
\tvmSetupScriptContent := fmt.Sprintf(`#!/bin/sh

%s
apk --update --no-cache add %s''',
        '''\tvmSetupScriptPath := fmt.Sprintf("%s%s", cfg.RootfsPath, cfg.VmSetupScriptPath)
\tproxyExport := ""
\tif p := resolveProxy(cfg.UserStore, ""); p != "" {
\t\tproxyExport = fmt.Sprintf("export http_proxy=%q\\nexport https_proxy=%q\\nexport HTTP_PROXY=%q\\nexport HTTPS_PROXY=%q\\n", p, p, p, p)
\t}
\tvmSetupScriptContent := fmt.Sprintf(`#!/bin/sh

%s
%s
apk --update --no-cache add %s''',
    ),
    (
        '''mkdir /.config /.cache
`, setupScript, packagesStr)''',
        '''mkdir /.config /.cache
`, proxyExport, setupScript, packagesStr)''',
    ),
    (
        '''func initRootfs(cfg *Config, nameserver string, setupScript string) error {
\tif _, err := os.Stat(cfg.ImageBasePath); err == nil {''',
        '''func initRootfs(cfg *Config, nameserver string, setupScript string, cliProxy string) error {
\tif proxyURL := resolveProxy(cfg.UserStore, cliProxy); proxyURL != "" {
\t\tfmt.Printf("Using network proxy: %s\\n", proxyURL)
\t\tos.Setenv("HTTP_PROXY", proxyURL)
\t\tos.Setenv("HTTPS_PROXY", proxyURL)
\t\tos.Setenv("http_proxy", proxyURL)
\t\tos.Setenv("https_proxy", proxyURL)
\t\tif parsed, err := url.Parse(proxyURL); err == nil {
\t\t\thttp.DefaultTransport = &http.Transport{Proxy: http.ProxyURL(parsed)}
\t\t}
\t}
\tif _, err := os.Stat(cfg.ImageBasePath); err == nil {''',
    ),
    (
        '\tvar setupScript string\n\tflag.StringVar(&nameserver, "n", DEFAULT_DNS_SERVER, "Nameserver IP to write into /etc/resolv.conf")\n',
        '\tvar setupScript string\n\tvar proxyFlag string\n\tflag.StringVar(&nameserver, "n", DEFAULT_DNS_SERVER, "Nameserver IP to write into /etc/resolv.conf")\n\tflag.StringVar(&proxyFlag, "proxy", "", "HTTP/HTTPS proxy URL for OCI downloads and package installation")\n',
    ),
    (
        '\terr = initRootfs(&cfg, nameserver, setupScript)\n',
        '\terr = initRootfs(&cfg, nameserver, setupScript, proxyFlag)\n',
    ),
]
for old, new in markers:
    if text.count(old) != 1:
        raise SystemExit(f"init-rootfs: HARD-STOP — runtime pin patch marker drifted in {path}: {old[:80]!r}")
    text = text.replace(old, new, 1)

if "alpine:latest" in text:
    raise SystemExit(f"init-rootfs: HARD-STOP — floating Alpine reference remains in {path}")
path.write_text(text)
print(f"init-rootfs: patched Docker reference parsing and default to {ref}")
PYEOF
}
