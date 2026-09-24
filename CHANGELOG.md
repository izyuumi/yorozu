# Changelog

## [0.4.0](https://github.com/izyuumi/yorozu/releases/tag/v0.4.0) (2026-09-24)

### Features

- **runtime:** title threads with the Mac's on-device model ([2824093](https://github.com/izyuumi/yorozu/commit/282409321a99e82e3bb409d8dd4c2c87f10f0778))
- **mac:** queue updates until local agents finish ([56abaad](https://github.com/izyuumi/yorozu/commit/56abaadfddeafc83e90ed588e856ba0edae42609))

### Bug Fixes

- **ios:** restart the TestFlight build number at 1 for each version ([e387028](https://github.com/izyuumi/yorozu/commit/e387028ebe4667fb0b2324034b4a2e72f71636a2))
- **mac:** find the shared resource bundle where build-mac.sh puts it \(\#31\) ([4e79a16](https://github.com/izyuumi/yorozu/commit/4e79a163888bb6a58410d7797f1153c95eeaa167))

### Documentation

- **release:** record native agent bridge release evidence for 0.3.0 \(282\) ([c89cce1](https://github.com/izyuumi/yorozu/commit/c89cce14e59d4e10703498a51e587115d39481e8))

### Maintenance

- **main:** release 0.4.0 ([b9d686e](https://github.com/izyuumi/yorozu/commit/b9d686eb28f82a775c75f6ef38f9a244f17b8aaa))

**Full history:** https://github.com/izyuumi/yorozu/compare/f78492cfc1494b1676cfd8a3f6b200a9293f39a2...3e281df0640c39e89f490d8803c27aa064263cd2

## [0.3.0](https://github.com/izyuumi/yorozu/commit/f78492cfc1494b1676cfd8a3f6b200a9293f39a2) (2026-09-24)


### Features

* **approval:** YOLO is granted on the Mac, for hours, never by a phone alone ([27365da](https://github.com/izyuumi/yorozu/commit/27365da85626a10f33de0e8959ed11c07a16b74f))
* **mac:** group general settings into sections ([4405b66](https://github.com/izyuumi/yorozu/commit/4405b667cb7f55af676275bec07f49ac15f044aa))
* **push:** approval pushes carry a sealed preview with the quick bit and the event they answer ([85940a0](https://github.com/izyuumi/yorozu/commit/85940a0eecaf77d1a13551586b563a1d3d967136))


### Bug Fixes

* **apps:** ask before a link replaces a pairing; open only web and mail from chat; trust no relay words ([e695661](https://github.com/izyuumi/yorozu/commit/e695661fa990fbdf400810e254c00fdb8b57a099))
* **apps:** keep channel counters with the keys, make Deny the default, allowlist the sidecar's environment ([8f3c650](https://github.com/izyuumi/yorozu/commit/8f3c650bf0473e99e51b2945c78dcd5628094e70))
* **ios:** archive with Apple Distribution so CI needs no development certificate ([6552339](https://github.com/izyuumi/yorozu/commit/65523399d602431b59aed87cdbcfa5449ca33422))
* **protocol:** one key per direction and a sequence number in every box ([09aeaa9](https://github.com/izyuumi/yorozu/commit/09aeaa981a924a4cc70302960dd77671c683b549))
* **relay:** bound what one client can cost the relay ([3c2e2a8](https://github.com/izyuumi/yorozu/commit/3c2e2a8abd02ec291c7a351322118f1f51ff693d))
* **relay:** trust the proxy's hop of X-Forwarded-For, drop strangers after ten seconds, and a self-hosted image that starts ([799b0cd](https://github.com/izyuumi/yorozu/commit/799b0cdcfb950ae827b1e048caeb6ae9dfa3ce06))
* **runtime:** atomic state writes, counters in their own file, malformed frames acked, YOLO requests coalesced ([f97b868](https://github.com/izyuumi/yorozu/commit/f97b868b846f1367c2a692b97721dfd120c99956))
* **runtime:** create the state directory 0700 on first run ([b12dd9a](https://github.com/izyuumi/yorozu/commit/b12dd9acf4729bec4de12d38b3d094168af1b0db))
* **runtime:** proof to move a device's relay key, a folder for every native turn, no crash on a bad frame ([a6b5504](https://github.com/izyuumi/yorozu/commit/a6b5504db822adc38df6b180995224d0d67ae334))
* **sync:** greet both released device channel formats ([b070621](https://github.com/izyuumi/yorozu/commit/b07062137631f6e1f94f8a9c9e1b032aeb114a4b))
* **sync:** support older Mac channels and name paired devices ([42f6ad7](https://github.com/izyuumi/yorozu/commit/42f6ad7d599b8225dc4a1bdcca8b7a754e8cbc14))
