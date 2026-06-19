# Контекст работ по VPN (общий)

## 2026-06-10: GRANIwg/AmneziaWG Android UAPI package fix

Пользователь тестировал SG/Vultr `149.28.139.231:4500` через GRANI v24 и AmneziaVPN. В AmneziaVPN ручной AWG v2/J-only конфиг на Wi-Fi мог оживать, а в GRANI соединение давало только единичные входящие пакеты. По Android-логам GRANI найден ключевой признак:

- `AmneziaWG/grani-awg E UAPIOpen: mkdir /data/data/org.amnezia.awg: permission denied`
- при этом `libwg-go` принимала параметры AWG (`jc=4,jmin=5,jmax=60,h1=1,h2=2,h3=3,h4=4`), handshake response приходил, но трафик не разворачивался.

Вывод: проблема уже не в портах и не в отсутствии J/H-параметров. Нативная `libwg-go.so` была собрана с `ANDROID_PACKAGE_NAME=org.amnezia.awg` и пыталась создать UAPI socket/cache в sandbox AmneziaVPN, куда приложение GRANI (`com.granivpn.mobile`) не имеет прав.

Сделанные правки:

- `mobile-app/android/third_party/amneziawg-android/tunnel/build.gradle.kts`
  - добавлено отдельное свойство `amneziawgAndroidPackageName` для CMake/Go `ANDROID_PACKAGE_NAME`;
  - `amneziawgPackageName=org.amnezia.awg` оставлен как Java/namespace package, чтобы не ломать vendored AmneziaWG Java/JNI структуру.
- `mobile-app/android/gradle.properties`
  - добавлено `amneziawgAndroidPackageName=com.granivpn.mobile`.
- `mobile-app/android/third_party/amneziawg-android/gradle.properties`
  - добавлено `amneziawgAndroidPackageName=com.granivpn.mobile`.

Проверки:

- `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter analyze lib/simple_vpn/simple_vpn_controller.dart lib/services/native_vpn_service.dart --no-fatal-infos --no-fatal-warnings`
  - успешно, остались только прежние info-level `use_super_parameters` в `native_vpn_service.dart`.
- `cd /opt/grani/mobile-app/android && ./gradlew :amneziawg-tunnel:clean :app:clean`
  - успешно.
- `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release`
  - успешно.
- Проверка `lib/arm64-v8a/libwg-go.so` внутри APK:
  - теперь содержит `/data/data/com.granivpn.mobile/cache/amneziawg`;
  - старого `/data/data/org.amnezia.awg/cache/amneziawg` в проверенной строке нет.

Собранный APK:

- сервер: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`
- локально: `outputs/grani-vpn-v24-awg-uapi-package-fix.apk`
- SHA256: `900cff49f1ac42b4d2b4e2563c0d17215112bc5c8d33bc821b474da6f149be49`

Что проверить на телефоне:

- установить этот APK поверх/после удаления старого;
- подключиться к Singapore;
- в логах больше не должно быть `UAPIOpen: mkdir /data/data/org.amnezia.awg: permission denied`;
- если пакеты всё еще не идут, следующий слой диагностики уже не package/UAPI, а runtime-сравнение AmneziaVPN AWG v2 vs GRANI `awg-go` после исправленного UAPI.

## 2026-06-10 14:45 UTC - SG root cause found: UFW blocked routed wg0 traffic

- User tested the APK with the native UAPI package fix. Result remained bad: Singapore still had only tiny incoming traffic.
- Fresh Android log showed the previous native sandbox error is gone:
  - no more `UAPIOpen: mkdir /data/data/org.amnezia.awg: permission denied`;
  - GRANI now loads `libwg-go.so`, applies `Jc=4,Jmin=5,Jmax=60,H1-H4=1..4`, starts `grani-awg`, receives the first handshake response;
  - then `awg-go` logs `Retrying handshake because we stopped hearing back after 15 seconds`.
- Backend correlation:
  - SG config issued at `14:36:58 UTC` for `user_id=1`, `server_id=8`;
  - SG session start at `14:37:13 UTC`, session `9f8d336b-a2cc-4ece-8c60-6c23fa46ba39`;
  - verifies later became `verified=False reason=stale_or_missing_handshake`, with tiny counters around `rx=5164 tx=110799`.
- Live SG check:
  - `wg0` on `149.28.139.231:4500` had peer `10.0.0.2` endpoint `94.180.243.40:49518`;
  - `ip -s link show wg0`: RX only `5164 bytes / 39 packets / 4 errors`, TX `110799 bytes / 653 packets / 78 errors`;
  - live config was correct minimal/J-default AWG: `Jc=4,Jmin=5,Jmax=60,H1=1,H2=2,H3=3,H4=4`, MTU `1280`, NAT to `enp1s0`.
- Direct root cause from SG kernel log:
  - UFW was blocking routed packets from the tunnel:
    - `[UFW BLOCK] IN=wg0 OUT=enp1s0 SRC=10.0.0.2 DST=1.1.1.1 ... DPT=53`
    - `[UFW BLOCK] IN=wg0 OUT=enp1s0 SRC=10.0.0.2 DST=9.9.9.9 ... DPT=853`
    - `[UFW BLOCK] IN=wg0 OUT=enp1s0 SRC=10.0.0.2 DST=13.56.92.194 ... DPT=443`
  - This explains the symptom exactly: handshake and a few tunnel packets exist, but DNS/HTTPS from VPN client are dropped by SG firewall before egress.
- Why previous PostUp rules did not save it:
  - SG UFW default is `deny (routed)`;
  - `awg-quick` PostUp appended broad `iptables -A FORWARD -i wg0 -j ACCEPT`, but UFW chains are evaluated before those appended rules;
  - therefore UFW could log/drop routed packets before they reached the later PostUp ACCEPT.
- Applied server-only fix on SG:
  - command: `ufw route allow in on wg0 out on enp1s0 comment "GRANI SG wg0 routed egress"`;
  - UFW now shows `Anywhere on enp1s0 ALLOW FWD Anywhere on wg0`;
  - `iptables -S ufw-user-forward` now includes `-A ufw-user-forward -i wg0 -o enp1s0 -j ACCEPT`.
- Sweden comparison:
  - Sweden UFW is inactive and had active traffic on the same device/public key immediately after switching to server id `5`;
  - backend verify for Sweden at `14:40:50 UTC` and later was `verified=True`, counters grew quickly (`rx=209964 tx=1805812` by `14:41:06 UTC`);
  - Sweden `wg0` had zero link errors.
- Next test:
  - On phone fully disconnect VPN, select Singapore, connect again.
  - Expected: SG no longer logs `[UFW BLOCK] IN=wg0 OUT=enp1s0` for `10.0.0.2`, and counters should grow beyond a few KB.
  - If it still fails, run live SG watch during reconnect: `wg show wg0`, `ip -s link show wg0`, `iptables -v -n -L ufw-user-forward`, `dmesg | grep "IN=wg0 OUT=enp1s0" | tail`.

## 2026-06-10 14:47 UTC - SG retest after UFW route allow

- User connected again after the SG UFW route rule was added.
- Live SG state after reconnect:
  - new/current app device key on SG is `zlyM4MV2...`, assigned `10.0.0.4/32`;
  - `wg show wg0` shows endpoint `94.180.243.40:38055`, latest handshake around 28-38 seconds;
  - transfer still small: roughly `3.05 KiB received / 49.72 KiB sent`;
  - `ip -s link show wg0` now has small counters and no TX errors, but RX errors increased to `5`.
- The new UFW forward rule is active and being hit:
  - `iptables -v -n -L ufw-user-forward` shows `11 packets / 699 bytes ACCEPT wg0 -> enp1s0`;
  - NAT for `10.0.0.0/24 -> enp1s0` also shows `11 packets / 699 bytes`;
  - no fresh post-fix `[UFW BLOCK] IN=wg0 OUT=enp1s0` was observed in the tail; the visible block lines were from before the rule.
- Backend correlation in the same window is suspicious:
  - SG config/session for device `e8a74313...` started at `14:45:05`/`14:45:38 UTC`;
  - then `session stop reason=user` at `14:46:07 UTC`;
  - verify for SG at `14:46:09 UTC` was `verified=True` but tiny counters `rx=1716 tx=24061`;
  - immediately after that backend issued config/session for Sweden `server_id=5` at `14:46:17`/`14:46:18 UTC`, then SG session start again at `14:46:29 UTC`.
- Interpretation:
  - SG UFW routed-drop was real and fixed, but SG still does not yet show healthy useful traffic;
  - initial suspicion of automatic client selection/cache jumping was reduced by user clarification below.
- User clarification:
  - sequence was manual: connect Singapore, see only ~6 packets, disconnect, connect Sweden, Sweden works, then return to Singapore;
  - therefore backend sequence `server_id=8 -> server_id=5 -> server_id=8` is expected and not proof of automatic server jumping.
- Follow-up live SG check after this clarification:
  - peer `10.0.0.4` endpoint still present, but latest handshake aged to ~1m52s;
  - transfer remained tiny: `3.05 KiB received / 58.69 KiB sent`;
  - `ufw-user-forward` and NAT counters stayed at `11 packets / 699 bytes`;
  - no fresh post-fix `[UFW BLOCK] IN=wg0 OUT=enp1s0` appeared;
  - route lookup from `10.0.0.4` via `wg0` to `1.1.1.1` goes out `enp1s0` correctly.
- Updated interpretation:
  - SG routed firewall problem is fixed, but after the first few forwarded packets the GRANI<->SG tunnel still stops producing useful traffic;
  - remaining suspect is not UFW forward anymore, but SG/AWG data path after initial handshake: provider/UDP path, SG kernel/AWG behavior, MTU/data packets, or GRANI embedded awg-go interaction with this node.
  - Sweden remains the control: same app path/key family works there with growing counters.

## 2026-06-10 14:56 UTC - Cross-provider comparison: common failing runtime class

- User correctly noted that "try another provider" was already done: Hetzner Finland/Germany and Vultr Singapore show the same handshake/tiny-packets class, while Sweden remains the only working-ish GRANI node.
- Live comparison was run for SE, FI, DE, SG.
- Working control, Sweden `SE-STO-01`:
  - Ubuntu `26.04 LTS`;
  - kernel `7.0.0-14-generic`;
  - `modinfo amneziawg`: version `1.0.0`, srcversion `81198FA101631BF9D6CB5CB`;
  - `awg tools`: `amneziawg-tools v1.0.20210914`;
  - UFW inactive;
  - current GRANI traffic grows normally on user device/key (`MiB` counters).
- Failing/new runtime class:
  - Finland `FI-HEL-01`: Ubuntu `24.04.4 LTS`, kernel `6.8.0-117-generic`, `amneziawg` module version `1.0.20251009`, srcversion `67D966748286DD592637A74`;
  - Germany `DE-FSN-01`: Ubuntu `24.04.4 LTS`, kernel `6.8.0-117-generic`, same `amneziawg` module version `1.0.20251009`;
  - Singapore `SG-SIN-01`: Ubuntu `24.04.4 LTS`, kernel `6.8.0-124-generic`, same `amneziawg` module version `1.0.20251009`;
  - all use `amneziawg-tools v1.0.20210914`.
- Important differences between the failing nodes:
  - providers differ (`Hetzner`, `Vultr`);
  - UFW differs (`FI/DE` inactive, `SG` active but route-block now fixed);
  - ports/profiles/MTU were varied (`51820`, `39060`, `443`, `4500`, `1280`, full S/H, J-only);
  - symptoms remained in the same class.
- Updated conclusion:
  - repeated failures across Hetzner and Vultr are unlikely to be solved by buying another random VPS;
  - the strongest common suspect is the host-level AmneziaWG runtime class on Ubuntu 24.04/kernel 6.8 with DKMS module `1.0.20251009`, or its interaction with GRANI's Android embedded `awg-go`;
  - Sweden works on a different kernel/module runtime class, so it should be treated as the reference to clone, not just as "another provider".
- Recommended next concrete experiment:
  - stop port/profile churn on SG/FI/DE;
  - pick one failing node, preferably FI or SG, and make it match Sweden's runtime as closely as possible:
    - same OS/kernel/module class if reproducible, or
    - move GRANI server-side AWG to a userspace/container runtime equivalent to known-working Amnezia instead of the host DKMS module;
  - only after that retest GRANI with the same phone/key.

## 2026-06-10 15:20 UTC - New Vultr Osaka node deployed as Sweden-runtime clone

- User created a new Vultr instance:
  - hostname/label: `grani-jp-osaka-01`;
  - public IPv4: `66.245.219.118`;
  - location: Osaka, JP;
  - image: Ubuntu `26.04 LTS x64`;
  - plan: `vc2-1c-1gb`, 1 vCPU, 1 GB RAM, 25 GB SSD;
  - SSH key initially: `do-login-20260325`.
- Baseline:
  - OS: Ubuntu `26.04 LTS`;
  - kernel: `7.0.0-22-generic`;
  - default route: `enp1s0` via `66.245.218.1`;
  - public IPv4: `66.245.219.118/23`;
  - UFW was active by default, only `22/tcp` allowed, routed policy `deny`.
- Important implementation choice:
  - did not run the old generic `setup-amneziawg.sh`, because it adds Amnezia PPA and could install the same newer DKMS runtime that failed on Ubuntu 24.04 nodes;
  - instead replicated the working Sweden runtime from source commits.
- Installed AmneziaWG kernel module:
  - source repo: `https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git`;
  - commit: `ac946a9df100a17d342b5982d1947deef1b51952`;
  - built against `linux-headers-7.0.0-22-generic`;
  - installed module result:
    - `version: 1.0.0`;
    - `srcversion: 81198FA101631BF9D6CB5CB`;
    - `vermagic: 7.0.0-22-generic SMP preempt mod_unload modversions`;
  - this matches the working Sweden module class (`version 1.0.0`, same srcversion), except for kernel patchlevel `7.0.0-22` vs Sweden `7.0.0-14`.
- Installed AmneziaWG tools:
  - source repo: `https://github.com/amnezia-vpn/amneziawg-tools.git`;
  - commit: `5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079`;
  - installed `/usr/bin/awg`, `/usr/bin/awg-quick`;
  - wrappers created:
    - `/usr/local/bin/wg -> /usr/bin/awg`;
    - `/usr/local/bin/wg-quick -> /usr/bin/awg-quick`;
  - `awg -v`: `amneziawg-tools v1.0.20210914`.
- Created and started GRANIwg interface:
  - config path: `/etc/amnezia/amneziawg/wg0.conf`;
  - interface: `wg0`;
  - address: `10.0.0.1/24`;
  - listen port: `51820`;
  - MTU: `1420`;
  - AWG params: `Jc=4,Jmin=5,Jmax=60`, runtime defaults show `H1-H4=1..4`;
  - NAT: `10.0.0.0/24 -> enp1s0 MASQUERADE`;
  - forwarding sysctl enabled in `/etc/sysctl.d/99-graniwg.conf`;
  - systemd unit added from Sweden pattern: `/usr/lib/systemd/system/awg-quick@.service`;
  - service `awg-quick@wg0` enabled and active.
- UFW on Osaka:
  - kept active, but fixed rules before first test:
    - `ufw allow 51820/udp comment "GRANIwg Osaka"`;
    - `ufw route allow in on wg0 out on enp1s0 comment "GRANI Osaka wg0 routed egress"`;
  - avoids the SG mistake where UFW routed deny blocked `wg0 -> public internet`.
- SSH management:
  - added existing `/root/.ssh/grani_nodes_ed25519.pub` from `grani-do` to Osaka `/root/.ssh/authorized_keys`;
  - verified `grani-do` can SSH to Osaka using `/root/.ssh/grani_nodes_ed25519`.
- Backend DB registration:
  - inserted/updated `servers` row:
    - `id=9`;
    - name `JP-OSA-01`;
    - country `Japan`, city `Osaka`, provider `Vultr`;
    - IP `66.245.219.118`;
    - `wireguard_port=51820`;
    - `is_active=true`, `status=online`, `graniwg_enabled=true`;
    - `wireguard_config_path=/etc/amnezia/amneziawg/wg0.conf`;
    - `wireguard_interface=wg0`;
    - `supported_protocols=["graniwg"]`;
    - `graniwg_obfuscation_key={"Jc":4,"Jmin":5,"Jmax":60}`;
    - `ssh_host=66.245.219.118`, `ssh_user=root`, `ssh_key_path=/root/.ssh/grani_nodes_ed25519`;
    - `ssh_key_content` copied from working managed server id `5`.
  - server public key: `SnJuqlY0Jnqbfor/+UP9oUamIgqiykLpJ1xs+r/avg4=`.
- Verification:
  - backend health now shows `total_servers=4`, `healthy=4`;
  - DB row for server id `9` has `health_status=healthy`, `last_health_check=2026-06-10 15:18:47`;
  - live check from `grani-do`: `awg-quick@wg0 active`, `wg show wg0` OK, UFW and route allow OK.
- No APK/AAB build was performed.
- Next phone test:
  - fully disconnect VPN;
  - refresh/reopen app if Osaka is not visible immediately;
  - select `Japan/Osaka` or `JP-OSA-01`;
  - connect and keep it connected for at least 60 seconds;
  - monitor server id `9` counters: `wg show wg0`, `ip -s link show wg0`, `iptables -v -n -L ufw-user-forward`, backend `/simple-vpn/session/verify`.

## 2026-06-10 15:26 UTC - Osaka first GRANI test failed, UFW disabled for exact Sweden comparison

- User tested Osaka `server_id=9`; result: same symptom, connected but no useful incoming packets.
- Backend confirms this was really Osaka:
  - prepared peer created for `user_id=1`, device `e8a74313-e8ff-4b5d-bd06-8060e0f68af0`, `server_id=9`, `vpn_ip=10.0.0.2`;
  - config issued at `15:21:11 UTC`;
  - session start at `15:21:11 UTC`, session `ae1127dd-6fa8-4a19-9ac9-d29eb2507985`;
  - verify after stop showed `verified=False reason=stale_or_missing_handshake`, `handshake_age=147`, `rx=1140`, `tx=9086`.
- Live Osaka state after first test:
  - peer `zlyM4MV2...` endpoint `94.180.243.40:37731`;
  - latest handshake aged ~3 minutes;
  - transfer only `1.11 KiB received / 8.87 KiB sent`;
  - `ip -s link wg0`: `RX 1140 bytes / 12 packets / 0 errors`, `TX 9086 bytes / 148 packets / 0 errors`;
  - UFW route/NAT counters showed only first tiny forwarded packets.
- Answer to "maybe native part is different":
  - Osaka tools/module now match Sweden as closely as practical:
    - `/usr/bin/awg`, `/usr/bin/awg-quick`;
    - wrappers `/usr/local/bin/wg -> /usr/bin/awg`, `/usr/local/bin/wg-quick -> /usr/bin/awg-quick`;
    - `amneziawg-tools v1.0.20210914`;
    - kernel module `version: 1.0.0`, `srcversion: 81198FA101631BF9D6CB5CB`;
  - therefore the previous Ubuntu 24.04/DKMS `1.0.20251009` hypothesis is no longer sufficient: Osaka uses the Sweden-like module class and still failed in GRANI.
- Remaining difference from Sweden before second test:
  - Osaka had UFW active, while Sweden UFW is inactive.
- Applied second server-only test on Osaka:
  - `ufw --force disable`;
  - current UFW status: inactive;
  - `FORWARD` policy now ACCEPT, NAT for `10.0.0.0/24 -> enp1s0` remains;
  - `wg0` remains active on UDP `51820`.
- Next test:
  - fully disconnect VPN;
  - select Osaka again;
  - connect and keep it connected for at least 60 seconds;
  - if Osaka still gives tiny RX with UFW inactive, next decisive test is a manual AmneziaVPN config on Osaka. If manual AmneziaVPN works and GRANI fails, the issue is client-side GRANI/AWG integration. If manual also fails, it is server/path/provider/runtime despite matching Sweden module.

Последнее обновление: 2026-05-08 (утренний цикл после лога 09:42-09:46)

## Цель

Стабилизировать подключение GRANI VPN так, чтобы:
- подключение поднималось предсказуемо;
- после подключения реально открывался интернет;
- текущий боевой тестовый путь оставался через `v2` (`/v2/vpn/xray/connect`).

## Зафиксированные правила (не менять без явного согласования)

- Активный тестовый канал: `v2` (`/v2/vpn/xray/connect`).
- Не переключать основной поток на `/vpn/session/prepare`, пока это явно не согласовано.
- Разбирать сбои сквозным способом: мобильные логи -> backend-логи -> состояние ноды/Xray.

## Текущие наблюдения из логов пользователя (2026-05-07 14:18-14:19)

1) Версия приложения корректная:
- в логах есть `build=23`.

2) Авторизация и API доступны:
- Google OAuth в этом логе проходит успешно (`/auth/google/callback` -> `status=200`, `google_auth_done ... success`);
- email flow также проходит успешно (`/auth/send-code` и `/auth/verify-code` -> `status=200`);
- `BASE URL` резолвится, control-plane запросы отправляются.

3) Главный текущий сбой на connect (новый формат):
- connect проходит до `COMMITTED` и трафик в туннеле есть (`VPN_TRAFFIC`, `proxy/vless/outbound` для `instagram` и `speedtest`);
- затем в том же сеансе приходит `stage_error` на `apply_verify/apply_protocol` и UI переводится в `idle`:
  - `fail_code=connect_fail_stage_apply_protocol__exception`
  - далее `connect_fail_stage_unknown__exception`.

4) Корреляция backend <-> mobile подтверждена:
- `POST /api/v2/vpn/xray/connect` -> `200` (`req_id=82f62995-...`);
- первый `GET /api/vpn/xray/apply-state` быстрый, но `is_applied=False` (`req_id=a1788bfe-...`);
- второй `GET /api/vpn/xray/apply-state` уходит в long-poll timeout:
  - `waited_ms=8133 timed_out=True is_applied=False` (`req_id=1688c14d-...`);
- в это же время на клиенте фиксируется exception "Конфигурация VPN еще применяется на сервере (ACK timeout)" и UI падает в ошибку.

5) Важное уточнение по Google:
- по предоставленному фрагменту именно Google-вход технически успешен;
- если в UI это воспринимается как "не сработало", проблема вероятнее в последующем экране/состоянии сессии, а не в `/auth/google/callback`.

## Гипотезы для следующей проверки (только `v2`)

1) Разрыв не в `v2/connect`, а в ACK-контуре `apply-state`: dataplane уже рабочий, но control-plane ACK не подтверждается вовремя.
2) Из-за этого клиент ошибочно интерпретирует рабочий туннель как fail и переводит UI в `idle`, провоцируя повторные connect/disconnect в живом сеансе.
3) Провал Speedtest вероятнее всего вторичный: тест стартует на фоне ложного fail-состояния и повторного цикла connect/disconnect, а не из-за отсутствия трафика в XRAY.

## Подтвержденные причины (по backend и ноде)

1) Backend `v2` раньше был ограничен только `xray_vless`:
- подтверждение: `HTTPException: 400 - V2 контур поддерживает только protocol=xray_vless`
- следствие: запросы `xray_reality` гарантированно падали на `400`.

2) По `v2` есть плавающие транспортные задержки:
- подтверждение: в клиентских логах `receiveTimeout` ~35s на отдельных `request_id`, затем успешный второй заход.
- в backend те же `request_id` обычно завершаются `200`, но с разным временем выполнения.

3) На ноде есть массовые `i/o timeout` на inbound `:4443`:
- подтверждение: `error.log` содержит серию `read tcp 45.12.132.94:4443-><client-ip>:<port>: i/o timeout`.
- это не блокирует все подключения, но ухудшает стабильность data-plane.

4) Шторм повторных connect на клиенте:
- частые подряд `xray_connect_start` при незавершенном предыдущем цикле ухудшают стабильность.
- визуально это выглядит как "зависания" и несформированный системный VPN-старт.

## План фиксов (согласовано)

1) Развязать UI-state от `apply-state timeout` после `COMMITTED`:
- если `serviceState=COMMITTED` и есть `VPN_TRAFFIC`, не переводить UI в `idle/error` при `apply-state timeout`;
- вводим промежуточный статус `connected_with_ack_delay` и оставляем кнопку "подключено".

2) Сделать `apply-state` неблокирующим post-commit шагом:
- после успешного native connect пайплайн возвращает success сразу;
- `apply-state` подтверждаем в фоне с ретраями, не ломая активный dataplane.

3) Умный retry для ACK:
- экспоненциальный backoff с джиттером (`1s -> 2s -> 4s -> 8s`, окно до `20-30s`);
- после окна только soft-warning, без мгновенного fail UI.

4) Backend: ускорить/стабилизировать подтверждение `apply-state`:
- вернуть ранний partial-ACK (например, `state=committed_dataplane`) до завершения отложенных шагов;
- логировать конкретную причину `is_applied=False` (какой флаг/этап не готов), чтобы убрать "черный ящик".

5) Guard от авто-перезапуска connect при живом туннеле:
- если активная сессия уже гонит трафик, блокировать новый `connect_pipeline_start`;
- показывать "соединение уже активно", чтобы убрать каскад reconnect/disconnect.

## Статус реализации по согласованным 5 фиксам

1) Развязать UI-state от `apply-state timeout` после `COMMITTED`:
- Статус: **сделано (mobile, v2 path)**.
- Что внедрено: при задержке ACK после рабочего dataplane фиксируется `connected_with_ack_delay` (soft warning), без принудительного перевода в `idle/error`.

2) Сделать `apply-state` неблокирующим post-commit шагом:
- Статус: **сделано (mobile)**.
- Что внедрено: ACK-проверка после подъема туннеля запущена как background-step; connect-cycle больше не падает синхронно из-за `ACK timeout`.

3) Умный retry для ACK (экспонента + джиттер + окно 20-30s):
- Статус: **сделано (mobile)**.
- Что внедрено: retry-план `1s -> 2s -> 4s -> 8s` + jitter, с hard window `28s`; по выходу окна — soft timeout без автосброса dataplane.

4) Backend partial-ACK + прозрачная причина `is_applied=False`:
- Статус: **сделано (backend)**.
- Что внедрено:
  - в `/api/vpn/xray/apply-state` добавлен `partial_ack_state=committed_dataplane` для `queued/dispatched/applying`;
  - добавлены `pending_reason` и `pending_flags` для расшифровки, почему `is_applied=False`;
  - long-poll `timed_out` теперь не срабатывает как hard-timeout при `partial_ack_state=committed_dataplane`.

5) Guard от авто-перезапуска connect при живом туннеле:
- Статус: **сделано (mobile)**.
- Что внедрено: guard `connect_pipeline_skip_live_tunnel` — при признаках активного proxy-туннеля повторный connect не стартует каскадно.

## План внедрения по уровням

### Уровень 1 (сразу, критично)
- стабилизировать сессию: ACK-timeout не должен ронять UI после `COMMITTED`;
- запретить повторный `connect/disconnect` при живом трафике.

### Уровень 2 (следом, transport)
- добавить второй профиль сервера/клиента для UDP-heavy нагрузки (Speedtest/медиа);
- роутить `speedtest mode` в UDP-дружественный профиль.

### Уровень 3 (policy)
- зафиксировать ожидания для `vless@tcp:4443`: базовый стабильный обход, но не профиль для пиковой скорости;
- для замера скорости/тяжелых сценариев переключать на throughput-профиль автоматически.

## Три уровня решения (операционный план)

1) **Immediate fix (сейчас, обязательно):**
- после `COMMITTED` не переводить UI в `idle/error` из-за `apply-state timeout`;
- запретить повторный `connect/disconnect` при живом трафике.

2) **Transport fix (следом):**
- добавить в backend+client второй UDP-дружественный профиль;
- добавить маршрутизацию "speedtest mode" на throughput/UDP-ориентированный канал.

3) **Policy fix:**
- `vless@tcp:4443` оставить как базовый стабильный обход;
- для speedtest/тяжелых сценариев переключать на throughput-профиль автоматически.

Текущий статус по уровням:
- Immediate: **в работе, большая часть mobile-фиксов уже внедрена**.
- Transport: **не начато**.
- Policy: **не начато**.

## Причина фейла Speedtest (рабочая гипотеза, обсуждаемо)

- туннель реально поднимался и трафик шел (`COMMITTED`, `VPN_TRAFFIC`, `proxy/vless/outbound` на `www.speedtest.net`, `user-api.speedtest.net`, `mapi.speedtest.net`);
- затем backend давал `apply-state ACK timeout` (`is_applied=False`, long-poll ~8s), и клиент ловил `stage_error`;
- после этого UI переходил в fail/idle и сессия становилась логически нестабильной в момент замера;
- для Speedtest это критично, так как ему нужны длинные стабильные TCP/UDP-сессии, а не только факт прохождения части пакетов;
- итог: вероятная причина провала не в отсутствии маршрута, а в рассинхроне `dataplane OK` vs `control-plane fail` в том же connect-цикле.

## Формулировка причины провала Speedtest (для сверки)

- Туннель поднимается и пропускает пакеты (`COMMITTED`, `VPN_TRAFFIC`, `proxy/vless/outbound` на speedtest endpoints).
- Почти сразу фиксируется `apply-state ACK timeout` (`is_applied=False`, long-poll ~8s), после чего клиент получает `stage_error`.
- UI/сессия дрейфует в fail/idle, и в момент замера поток становится логически нестабильным.
- Для Speedtest это критично: нужны длинные устойчивые TCP/UDP-потоки, а не единичный успешный проход пакетов.
- Вывод: основная причина — рассинхрон `dataplane OK` и `control-plane fail`, а не отсутствие маршрута как такового.

## Журнал изменений

- 2026-05-07: В мобильном коде возвращен основной путь на `v2`.
- 2026-05-07: Добавлен этот общий файл контекста для непрерывности работ.
- 2026-05-07: В backend `v2` добавлена поддержка `xray_reality` (кроме `xray_vless`).
- 2026-05-07: В mobile-app добавлен cooldown между connect-пайплайнами (anti-storm, 1200ms).
- 2026-05-07: В mobile-app укорочен первый timeout запроса `v2` (до 12s), чтобы быстрее выходить в retry/failover.
- 2026-05-07: Добавлен жесткий session-guard для connect-цикла и stage-логи `after_fetch_config`, `before_apply_config`, `after_apply_config`, `native_connect_result`, `commit_result`.
- 2026-05-07: На время диагностики включен режим `manual connect only` (блок автопереподключения при смене сети).
- 2026-05-07: Зафиксирован кейс `COMMITTED + internal probes OK`, но прикладной интернет (Speedtest/Instagram) не работает.
- 2026-05-07: Исправлен вывод `connect_stage` в release logcat — добавлен прямой `debugPrint('[connect_stage] ...')` в `VpnService`.
- 2026-05-07: Подтверждено по новому логу: `connect_stage` действительно появился в release logcat.
- 2026-05-07: Новый текущий фокус: connect падает до стадии `after_fetch_config` (есть `attempt_start`, затем `result=failed` без промежуточных стадий).
- 2026-05-07: Добавлены stage-specific error логи в connect executor (`stage_error`, `attempt_error`) с `fail_code`, `fail_stage`, `error_type`, `elapsed_ms`.
- 2026-05-07: Добавлена классификация `CONNECT_FAIL_STAGE` (формат `connect_fail_stage_<stage>_<reason>`), сохраняется в сессии и уходит в `connect_pipeline_finish`.
- 2026-05-07: Добавлены stage-таймеры (`stage_elapsed`) по блокам `prerequisites`, `get_config`, `apply_verify`.
- 2026-05-07: Для fail-пути добавлен `ConnectionLogger.flushDiagnosticsOnConnectFail()` — принудительный диагностический flush при ошибке connect.
- 2026-05-07: Расширен critical flush policy для `stage_error` / `attempt_error` / `connect_pipeline_finish` и `error_code=connect_fail_stage_*`.
- 2026-05-07: Добавлен UI anti-storm lock в tap flow: параллельный повторный connect tap игнорируется до завершения текущего tap-flow.
- 2026-05-07: Добавлен diagnostic single-tap cooldown 20s для ручных connect-попыток (чтобы убрать шторм повторных ручных запусков).
- 2026-05-07: Усилена корреляция `v2`: в `after_fetch_config` теперь явно логируются `request_id`, `correlation_id`, `connection_session_id`.
- 2026-05-07: ACK-проверка `apply-state` после подъема туннеля переведена в background soft-mode: connect больше не падает из-за `ACK timeout`.
- 2026-05-07: Добавлен stage `connected_with_ack_delay` (soft warning) вместо перевода UI в `idle/error` при задержке control-plane ACK.
- 2026-05-07: Добавлен guard `connect_pipeline_skip_live_tunnel`: повторный connect блокируется, если обнаружен живой proxy-туннель в состоянии `idle/error`.
- 2026-05-07: `pendingApplyConfigRevision` больше не очищается сразу в `connected_local`; очищается только после успешного background ACK.
- 2026-05-07: В mobile `apply-ack` retry доведен до целевого профиля: `1/2/4/8s` + jitter, окно ожидания `28s`.
- 2026-05-07: В backend `apply-state` добавлен partial ACK (`partial_ack_state=committed_dataplane`) и диагностические причины pending (`pending_reason`, `pending_flags`).
- 2026-05-07: В backend long-poll `apply-state` перестал трактовать partial-ack как жесткий timeout (`timed_out=false` при committed_dataplane).
- 2026-05-07: Собран новый `app-release.apk` (arm64, release) после внедрения ACK-fixes; артефакт: `mobile-app/build/app/outputs/flutter-apk/app-release.apk`.
- 2026-05-07: Перезапущен backend-контейнер `granivpn_api`, статус после рестарта: `healthy`.

## Заметки (пользователь + агент)

Раздел для коротких обновлений, договоренностей и решений.

- [ ] 

## Обновление по логу 2026-05-08 (09:03-09:06)

1) Базовый connect теперь стабилен для обоих протоколов:
- `xray_vless` и `xray_reality` доходят до `DATAPLANE_VERIFIED -> COMMITTED`;
- `CONNECTIVITY_PROBE` успешен (`public_internet ok=true`, `api_health ok=true`);
- `connect_pipeline_finish result=success`, UI остается в `connected`;
- при задержке ACK фиксируется `connected_with_ack_delay` (soft), без срыва в `idle/error`.

2) Трафик приложений через туннель реально идет:
- есть `proxy/vless/outbound` на `www.speedtest.net`, `user-api.speedtest.net`, `mapi.speedtest.net`;
- есть постоянный трафик на `youtubei.googleapis.com`, `redirector.googlevideo.com`, `instagram` endpoints.

3) Новый доминирующий симптом (transport-level):
- массово повторяются ошибки вида:
  - `transport/internet/udp: failed to handle UDP input > io: read/write on closed pipe`
  - `failed to write first UDP payload > io: read/write on closed pipe`
  - `proxy/vless/outbound: failed to find an available destination ... dial tcp 45.12.132.94:2053: operation was canceled`
- это появляется уже после успешного `COMMITTED`, то есть проблема не в подъеме туннеля, а в устойчивости data-plane при прикладной нагрузке.

4) Рабочая трактовка причины Speedtest/YouTube fail на текущем этапе:
- control-plane/ACK-часть больше не является primary-root-cause;
- primary-root-cause сместился в transport degradation на длинных/массовых потоках (особенно UDP-heavy сценарии) в связке текущего mobile routing + single-port reality path.

5) Что проверять и править следующим шагом (приоритет):
- включить диагностический режим `GLOBAL_UDP_443_BLOCK_ENABLED=true` (форс fallback с QUIC на TCP) и сравнить поведение Speedtest/YouTube;
- на стороне backend/node поднять диагностику по порту `2053` (реальный accept/close/error pattern на том же временном окне);
- добавить отдельный throughput-профиль (UDP-friendly) и не смешивать его с базовым bypass-профилем.

## Журнал изменений (добавлено 2026-05-08)

- 2026-05-08: Подтверждено по свежему логу: `vless` и `reality` стабильно доходят до `COMMITTED`; UI не падает в fail из-за ACK-timeout (soft-stage `connected_with_ack_delay` работает как задумано).
- 2026-05-08: Зафиксирован новый основной симптом после `COMMITTED`: массовые transport ошибки `udp read/write on closed pipe` и периодические `failed to find an available destination ... dial tcp 45.12.132.94:2053: operation was canceled`.
- 2026-05-08: Root-cause-фокус смещен с control-plane ACK на data-plane transport degradation под прикладной нагрузкой (Speedtest/YouTube/Instagram).
- 2026-05-08: Включен диагностический `GLOBAL_UDP_443_BLOCK_ENABLED=true` в mobile (`XrayRoutingHelper`) для принудительного fallback с QUIC на TCP в рамках проверки transport-гипотезы.

## Уточнение по отчету (по вопросу пользователя)

1) Логи backend и ноды в отчете анализировались:
- backend: `v2 connect=200`, далее повторяемый `apply-state timed_out ~8s` при `is_applied=False`;
- node: `xray-v2` активен, порты подняты, отдельного "hard down" не найдено; в error-потоке много внешнего шумового сканирования.

2) Почему предыдущий тест получился идентичен предпоследнему:
- APK был фактически без активного QUIC-block (в logcat видно `injectQuicBlockRules: disabled (GLOBAL_UDP_443_BLOCK_ENABLED=false)`),
- то есть тест шел по практически той же transport-конфигурации, поэтому симптомы повторились.

3) Что зафиксировано как обязательное перед следующим сравнительным прогоном:
- принудительно включить QUIC-block с явным маркером в logcat;
- добавить отдельный анти-шторм UDP guard на клиенте, чтобы не разгонять лавину UDP re-dial после `closed pipe`;
- после этого пересобрать APK и повторить тест уже на новой сборке.

## Журнал изменений (добавлено 2026-05-08, второй цикл)

- 2026-05-08: Добавлен явный маркер QUIC-block в `XrayRoutingHelper`: `quic_block_forced_v2_2026_05_08` (логируется при enabled/disabled и при применении routing).
- 2026-05-08: Принудительный QUIC-block подтверждается отдельной строкой logcat: `[ROUTING_MARKER] marker=quic_block_forced_v2_2026_05_08 enabled=true`.
- 2026-05-08: Добавлен анти-лавинный UDP guard в `Tun2SocksProcessService`: `GLOBAL_UDP_REDIAL_GUARD_ENABLED=true`.
- 2026-05-08: При старте tun2socks теперь логируется маркер `udp_redial_guard_v1_2026_05_08` и фактический режим `forward_udp=false` для верификации, что APK действительно новый и защита активна.

## Обновление по логу 2026-05-08 (10:25-10:27, после сборки с QUIC-marker)

1) Новый APK подтвержден:
- в logcat есть `injectQuicBlockRules ... marker=quic_block_forced_v2_2026_05_08` и `[ROUTING_MARKER] ... enabled=true`.

2) Основной новый стоп-фактор:
- туннель и dataplane живы (`proxy/vless/outbound` на Speedtest/Instagram/YouTube есть), но connect в UI падает по timeout:
  - `VPN не вышел в COMMITTED за отведенное время`
  - `connect_fail_stage_apply_protocol__exception`.
- в этот же цикл есть probe:
  - `public_internet ok=true`
  - `api_health ok=false` с `UnknownHostException api.granilink.com`.

3) Вывод по root-cause на этом этапе:
- текущая причина рассинхрона "в шторке подключено / в UI fail" — слишком жесткий commit-gate по `api_health`;
- при рабочем dataplane и временном DNS-fail до `api.granilink.com` сервис не выставляет `COMMITTED`, и Flutter-пайплайн уходит в fail.

## Журнал изменений (добавлено 2026-05-08, третий цикл)

- 2026-05-08: В `GraniVpnService.runPostConnectConnectivityProbes()` изменен commit-gate: `COMMITTED` теперь ставится по факту `public_internet ok=true` (dataplane primary), даже если `api_health` временно degraded.
- 2026-05-08: Добавлен явный статус `ok_dataplane_control_plane_degraded` и флаг `control_plane_degraded` в `[CONNECTIVITY_PROBE]` лог/emit payload для прозрачной диагностики без ложного UI fail.

## Кратко: что изменили и чего добиваемся

Что изменили в этом цикле:
- перевели commit-gate на dataplane-priority: если `public_internet ok=true`, сервис может выставлять `COMMITTED` даже при временном `api_health` fail;
- сохранили прозрачность диагностики: добавлены `ok_dataplane_control_plane_degraded` и флаг `control_plane_degraded`;
- оставили включенными диагностические маркеры QUIC-block (`quic_block_forced_v2_2026_05_08`) и UDP-guard (`udp_redial_guard_v1_2026_05_08`) для верификации APK.

Чего хотим добиться на следующем тесте:
- убрать рассинхрон "в шторке VPN есть, в UI fail" (ложный fail из-за commit-gate);
- получить стабильный `COMMITTED` без повторных циклов connect при живом туннеле;
- после этого отдельно измерить реальную прикладную проходимость (Speedtest/YouTube/Instagram) уже без артефакта state-machine.

## Срез server+node перед новым APK (2026-05-08, по запросу)

1) Backend/API жив и держит node-control loop стабильно:
- регулярные `heartbeat` и `assignment` идут с `status=200`;
- health-check стабилен, признаков падения API в окне анализа нет.

2) В момент клиентских connect-сессий (`/api/v2/vpn/xray/connect`) сохраняется старый ACK-паттерн:
- `v2 connect` для `xray_vless` и `xray_reality` завершается `200`;
- затем `/api/vpn/xray/apply-state` дает быстрый snapshot `is_applied=False`;
- после этого long-poll снова фиксируется как `waited_ms~8s timed_out=True is_applied=False` (видно в backend perf-логах для request-id текущей сессии).

3) На ноде `xray-v2` сервис активен, порты подняты корректно:
- `xray-v2` в `active (running)`;
- слушаются `:4443`, `:2053`, `:8443`;
- критических `crash/restart-loop` в текущем окне не обнаружено.

4) Нодовые "сбои в чате ошибок" в основном представлены внешним шумом/сканированием:
- массовые `REALITY processed invalid connection` (server name mismatch / failed to read client hello / unsupported TLS version);
- массовые `proxy/vless invalid request version` и `invalid request user id`;
- это подтверждает сильный фон невалидного входящего трафика на публичные порты.

5) По этому срезу ключевой вывод:
- backend+node сейчас не показывают явного "фатала" уровня down;
- есть два параллельных фактора: (а) длительный/неполный ACK-контур `apply-state`, (б) высокий фон невалидных входящих коннектов на ноде;
- следующий шаг диагностики делаем уже с этим baseline: сверяем новый мобильный прогон с теми же метриками `apply-state` и нодовым error/access, чтобы отделить "шум сканеров" от реального пользовательского трафика.

## Обновление 2026-05-08 (UI моменты + фиксы перед новой сборкой)

Замечания из пользовательского теста:
- в момент, когда в шторке уже появляются иконки GRANI + ключ, в приложении кольцо подключения продолжает крутиться;
- при отключении иконка GRANI пропадает раньше, чем исчезает системный ключ (туннель еще жив).

Принятые правки:
- `mobile-app/lib/services/vpn_service.dart`:
  - после успешного native apply состояние UI переводится в `connected` сразу (без ожидания verify-этапа);
  - verify остается диагностическим, но не держит UI в "крутилке", если туннель уже поднят.
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt`:
  - перед `stopForeground(...)` добавлено ожидание фактического закрытия TUN (`lastTunState=closed/idle`, окно до 4s);
  - цель: убрать рассинхрон "иконка GRANI уже исчезла, а ключ VPN еще виден".
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayRoutingHelper.kt`:
  - для throughput-теста отключен глобальный QUIC-block (`GLOBAL_UDP_443_BLOCK_ENABLED=false`), marker в логах сохранен.
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/Tun2SocksProcessService.kt`:
  - выключен diagnostic UDP-guard (`GLOBAL_UDP_REDIAL_GUARD_ENABLED=false`), UDP forwarding возвращен (`forward_udp=true`).

Дальше по приоритету:
- сохранить текущие commit-gate и ACK-soft-fail фиксы;
- ослабить диагностические транспортные ограничения для throughput-теста (возврат UDP forwarding / селективный QUIC-block), затем пересборка APK и повторный прогон Speedtest/YouTube/Instagram.

## Обновление 2026-05-08 (разрыв петли prerequisites/device_register)

Новый подтвержденный блокер по логам:
- connect не доходил до запуска VPN;
- падение происходило на `prerequisites` с `ctx_stage=device_register` и `TimeoutException` (~16s), что создавало цикл "connect fail -> повтор".

Сделанные изменения:
- `ensureDeviceRegistered` в connect-пайплайне переведен в soft-режим:
  - вызов в prerequisites теперь с `verifyQuota=false` и коротким budget (`timeout=3s`);
  - при timeout/connect-error connect продолжает идти дальше (не роняется до старта VPN).
- hard-stop по лимиту устройств сохранен:
  - при `DeviceLimitException` поведение не меняли (ошибка по лимиту по-прежнему блокирующая).
- проверка квоты (`_verifyDeviceSlotQuotaOrThrow`) вынесена из blocking пути connect:
  - при `verifyQuota=false` выполняется в фоне через `unawaited`, чтобы не держать `prerequisites`.

Ожидаемый эффект:
- убрать текущую петлю "timeout на device_register до старта VPN";
- вернуть тесты к реальному dataplane/transport сценарию.

## Обновление 2026-05-08 (текущий root-cause и масштабирование)

Что зафиксировали по итогам анализа backend+node логов:
- истинная причина "VPN подключен, но Speedtest/YouTube не работает" сейчас в `dataplane` на ноде, а не в auth/UI/connect-flow;
- узкое место: inbound `45.12.132.94:4443` теряет устойчивость под прикладной нагрузкой (серии `i/o timeout` на пользовательский IP);
- ранее внедренные ACK/UI фиксы убрали ложные state-fail, но не устранили transport-деградацию.

Подтверждение в оперативных сигналах (скрины edge-алертов):
- в чате лог-бота повторяются `[EDGE ALERT] prod-hu-bud-01` с `pending_state > 0`;
- далее приходят `[EDGE RECOVERY] ... edge alerts normalized`;
- цикл "alert -> recovery -> alert" указывает на дрожание control-loop/применения состояний, что согласуется с `apply-state is_applied=False` и transport-нестабильностью в то же окно.

Вывод по масштабированию:
- если деградация проявляется уже на одном активном тестовом пользователе, при 10+ пользователях риск лавинообразных обрывов высокий;
- текущий профиль `vless@tcp:4443` в таком состоянии нельзя считать готовым к нагрузке heavy-сценариев (Speedtest/видео).

## План стабилизации ноды (приоритет P0 -> P1)

P0 (сделать первым, без смены клиентского канала `v2`):
- стабилизировать жизненный цикл `xray-v2`: убрать частые restart/reload в рабочем окне, добавить debounce/single-flight на применение конфигов;
- изолировать шум сканеров на публичных портах (`4443/2053/8443`): rate-limit + conn-limit + fail2ban по сигнатурам `invalid request version/user id`;
- включить расширенную диагностику именно по пользовательскому IP в окно теста (access/error correlation), чтобы отделять легитимный трафик от фонового шума.

P1 (сразу после P0):
- тюнинг transport-параметров Xray/сокетов для long-flow (timeout/keepalive, проверка MTU/MSS);
- добавить отдельный throughput-профиль (UDP-friendly) для heavy-трафика, не смешивая его с базовым bypass-профилем на `4443`.

Критерий успеха стабилизации:
- в тестовом окне нет серийных `read tcp ...:4443-><client_ip>:* i/o timeout`;
- нет циклов restart `xray-v2` в момент активного пользовательского трафика;
- Speedtest/YouTube проходят на стабильной сессии без ложных reconnect/fail.

## Выполнено 2026-05-08 (реализация P0+P1)

Сделанные изменения в backend/node tooling:
- `backend/services/edge_enqueue.py`:
  - добавлен coalescing для `pending` assignment в debounce-окне (обновляем существующий `pending`, не плодим новые);
  - сохранена идемпотентность по `expected_hash`, добавлена защита от роста `pending_state` при частых апдейтах.
- `backend/api/internal_node.py`:
  - добавлен авто-skip assignment, если `expected_hash` уже совпадает с `edge_reported_config_hash` (задание закрывается как `already_applied_by_hash_match`);
  - добавлен `force dispatch` после `xray_edge_dispatch_defer_max_sec`, чтобы исключить вечный `poll_defer` и циклы pending-alert.
- `backend/core/config.py`:
  - добавлены настройки:
    - `xray_edge_enqueue_debounce_sec=45`
    - `xray_edge_dispatch_defer_max_sec=150`
- `backend/infrastructure/external/xray_manager.py`:
  - добавлен `transport tuning guard` (`policy.levels/system` defaults для long-flow) при чтении/обновлении конфига.
- `backend/scripts/edge-node/poll-and-apply.sh`:
  - изменено применение конфига: сначала `systemctl reload`, fallback в `restart` (меньше разрывов активных сессий при применении).
- `server-config/scripts/apply-xray-v2-rate-limit.sh`:
  - усилен anti-scan guard (`connlimit` + tighter new-connection rate).
- `server-config/scripts/apply-xray-v2-transport-sysctl.sh`:
  - добавлен новый скрипт transport tuning (TCP keepalive/backlog/syn backlog/tw_reuse/fin timeout).

Проверка после правок:
- прогнаны целевые тесты backend (`test_internal_node_assignment`, `test_edge_enqueue`, `test_vpn_tasks_apply_xray`) — все `PASSED` (14/14).
- собран новый APK (arm64 release): `mobile-app/build/app/outputs/flutter-apk/app-release.apk`.

## Применение hardening на HU-BUD-01 (2026-05-08, выполнено)

Hardening применен удаленно через `RemoteVPNManager` (источник SSH-ключа: `servers.ssh_key_content` в БД) на ноде `HU-BUD-01` (`45.12.132.94`):
- применен anti-scan chain `XRAYV2_GUARD` и hooks на `INPUT` для портов `4443/2053/8443`;
- применен transport sysctl (`/etc/sysctl.d/99-grani-xray-transport.conf`);
- проверен jail `fail2ban` `xray-v2-noise` (active, без текущих банов на момент проверки).

Факт-проверка на ноде после применения:
- `systemctl is-active xray-v2` -> `active`;
- `ss -ltn` показывает listen на `*:4443`, `*:2053`, `*:8443`;
- `sysctl` подтверждает значения:
  - `net.ipv4.tcp_keepalive_time=120`
  - `net.ipv4.tcp_keepalive_intvl=15`
  - `net.ipv4.tcp_keepalive_probes=5`
  - `net.core.somaxconn=4096`
  - `net.ipv4.tcp_max_syn_backlog=8192`.

## Диагностика transport окна 90s (2026-05-08, выполнено)

Цель: подтвердить деградацию data-plane на уровне ноды в коротком окне наблюдения.
Запуск выполнен удаленно на HU-BUD-01 через `RemoteVPNManager` (read-only), с фильтром по клиентскому IP `94.180.243.40`.

Что измеряли:
- `/proc/net/snmp` (`Tcp.RetransSegs`) до/после 90 секунд;
- `ss -tin sport=:4443` каждые 5 секунд (retrans/lost/rtt/cwnd/sостояния);
- `xray error.log` по связке `94.180.243.40` + `:4443`;
- restart-события `xray-v2` за день.

Результат:
- `Tcp.RetransSegs` вырос с `29396526` до `29396600` за 90с (`+74`);
- в `ss -tin` устойчиво фиксировались потоки `FIN-WAIT-1` с `unacked=1 retrans=1/... lost=1` одновременно с большим числом `ESTAB`;
- в `error.log` сохраняется серия `read tcp 45.12.132.94:4443->94.180.243.40:*: i/o timeout`;
- в дневном журнале есть множественные restart `xray-v2`, включая `12:16:20` (окно пользовательского трафика).

Вывод:
- деградация подтверждена именно на transport-уровне ноды (`:4443`) при активной пользовательской сессии;
- primary bottleneck остается в устойчивости long-lived потоков (churn/retrans/timeouts), а не в auth/connect-state;
- control-plane ACK timeout остается сопутствующим шумом, но не объясняет сам transport-fail.

## Обновление 2026-05-08 (форс-пакет P0/P1 выполнен)

Сделано по приоритетам:
- **P0 / restart guard**: `backend/scripts/edge-node/poll-and-apply.sh`
  - добавлен жесткий блок fallback `restart`, если есть активные data-plane TCP-сессии на портах `4443/2053/8443`;
  - добавлено safe-window перед restart (`GRANI_XRAY_SAFE_WINDOW_SEC`, по умолчанию 20s): restart разрешается только если окно полностью без активных сессий;
  - при срабатывании guard assignment завершается `failed` с явной причиной (`reload_failed_restart_blocked_*`) вместо разрыва активного трафика.
- **P0 / node diagnostics по client IP**:
  - добавлен новый read-only скрипт `backend/scripts/diagnostics_hu_bud_client_ip_window.py`;
  - собирает в тестовом окне: `ss -tin` по `:4443` и client IP, `conntrack` snapshot/entries, дельту `Tcp.RetransSegs`, tail `xray error.log` по `client_ip|:4443`.
- **P1 / throughput profile (heavy traffic off baseline 4443)**:
  - в `backend/api/xray_v2.py` добавлен `traffic_profile` в `POST /api/v2/vpn/xray/connect`;
  - для `traffic_profile in {throughput, heavy, speedtest}` запрос с `protocol=xray_vless` автоматически переводится в `xray_reality` (профиль через отдельный reality-канал вместо базового `vless@4443`).
- **P1 / inbound stability для :4443**:
  - усилен guard в `backend/infrastructure/external/xray_manager.py::_ensure_xray_transport_tuning`;
  - для `vless` inbound на `:4443` принудительно/идемпотентно добавляются стабильные tcp/sockopt параметры (`tcpFastOpen`, `tcpNoDelay`, `tcpKeepAliveIdle`, `header=none`) и sniffing-профиль (`http/tls/quic`) для снижения churn/idle деградации.
- **P1 / ACK-path without longpoll timeout noise**:
  - в `backend/api/xray.py` long-poll `apply-state` теперь прерывается сразу при `partial_ack_state=committed_dataplane` (не ждет весь timeout);
  - `timed_out`/`retry_after_sec` для partial-ack больше не маркируются как timeout-шум.

Ожидаемый эффект текущего пакета:
- исключить restart-разрывы в активной пользовательской сессии;
- ускорить и очистить ACK-путь (меньше ложных `timed_out=True` при уже поднятом dataplane);
- вынести heavy-трафик из базового `vless@4443` через throughput-профиль;
- получить воспроизводимую, узконаправленную диагностику transport-провала в окно теста по конкретному IP.

## Проверка после форс-пакета (2026-05-08, окно 90s по client IP)

Запуск:
- `PYTHONPATH=/opt/grani/backend python3 backend/scripts/diagnostics_hu_bud_client_ip_window.py --server-name HU-BUD-01 --client-ip 94.180.243.40 --window-sec 90 --interval-sec 5`

Наблюдение в этом прогоне:
- в течение окна выборка `ss/conntrack` по `94.180.243.40` не показала активных TCP-сессий (`conntrack_entries: 0`);
- в tail `xray error.log` сохраняется плотная серия `read tcp 45.12.132.94:4443->94.180.243.40:*: i/o timeout` (т.е. transport-проблема по `:4443` остается воспроизводимой в рабочих окнах трафика);
- значит текущий прогон был диагностически "тихий" по live-трафику, но не опроверг уже подтвержденную transport-деградацию.

Практический вывод:
- для финального сравнения "до/после форс-пакета" нужно запускать это окно строго синхронно с активным тестом пользователя (Speedtest/YouTube), иначе live-счетчики могут быть нулевыми.

## Синхронный прогон с активным тестом (2026-05-08, выполнено)

Запуск выполнен синхронно с пользовательским тестом:
- `PYTHONPATH=/opt/grani/backend python3 backend/scripts/diagnostics_hu_bud_client_ip_window.py --server-name HU-BUD-01 --client-ip 94.180.243.40 --window-sec 90 --interval-sec 5`

Фактическая картина в live-окне:
- `ss -tin` зафиксировал большое число одновременных `ESTAB` + `FIN-WAIT-1` с паттерном `unacked=1 retrans=1 lost=1` на `45.12.132.94:4443 <-> 94.180.243.40:*`;
- в части ESTAB наблюдался рост RTT до ~`158–229ms` (при базовом диапазоне ~`58–62ms`), что согласуется с деградацией long-lived flow;
- tail `xray error.log` в этом же окне показал плотную непрерывную серию `read tcp 45.12.132.94:4443->94.180.243.40:*: i/o timeout`.

Вывод по синхронному прогону:
- root-cause подтвержден повторно и уже в синхронном live-тесте: деградация transport/data-plane на inbound `:4443` сохраняется;
- P0/P1 форс-пакет устранил часть control-plane/операционного шума, но не убрал сам transport-failure под нагрузкой на `vless@4443`.

## Реальная починка после синхронного теста (2026-05-08, выполнено)

Цель: не только подтверждать сбой, а сразу уменьшить вероятность деградации на `vless@4443` и увести heavy-трафик в throughput-профиль.

Выполненные изменения:
- `backend/api/xray_v2.py`:
  - добавлен default-routing для v2: если клиент просит `xray_vless`, то при включенном флаге `xray_v2_force_throughput_profile_for_vless=true` запрос автоматически получает профиль `throughput`;
  - профиль `throughput` продолжает принудительно резолвиться в `xray_reality` (heavy-трафик не идет через baseline `vless@4443`);
  - в логах `xray-v2 connect` теперь фиксируется `traffic_profile`.
- `backend/core/config.py`:
  - добавлены конфиги:
    - `xray_v2_force_throughput_profile_for_vless = true`
    - `xray_v2_default_traffic_profile = "throughput"`
- `mobile-app/lib/services/xray_connection_handler.dart`:
  - в запрос `/v2/vpn/xray/connect` добавлен `traffic_profile='throughput'` для `VpnProtocol.xrayVless`;
  - это синхронизирует клиент и backend в стратегии "heavy off 4443".
- `server-config/scripts/apply-xray-v2-rate-limit.sh`:
  - добавлена отдельная цепочка `XRAYV2_4443_CHURN_GUARD` для `:4443` (более строгий SYN-rate gate);
  - baseline anti-scan chain сохранен, но `4443` теперь дополнительно защищен от short-flow storm/churn;
  - скрипт переведен в compatibility-режим (без зависимостей от `conntrack/state/connlimit`) для предсказуемого применения на нодах с урезанным iptables match set.

Что это дает по сути:
- baseline `vless@4443` разгружается от тяжелого burst-трафика;
- уменьшается вероятность каскада `FIN-WAIT-1 + retrans/lost + i/o timeout` на `:4443`;
- дальше проверяем эффект повторным синхронным тестом (Speedtest/YouTube) и сравниваем density timeout-ов и долю FIN-WAIT-1.

Операционный статус на ноде HU-BUD-01:
- попытка применить iptables churn-guard напрямую на ноде выявила ограниченный набор match-модулей (`conntrack/state/connlimit/limit` в текущем окружении недоступны для правил);
- из-за этого правила anti-churn для `:4443` нужно накатывать через совместимый для ноды firewall-контур (nftables/firewalld policy), а не через текущий iptables-скрипт 1:1.

## Переход на "старые рельсы" (SSH apply) — выполнено 2026-05-08

Решение:
- подтвержден rollback с edge-agent контура на legacy SSH apply для `HU-BUD-01`.

Что сделано:
- добавлен и выполнен скрипт `backend/scripts/switch_hu_bud_to_ssh_rails.py`;
- в БД для `servers.name=HU-BUD-01` очищены edge-поля:
  - `edge_agent_token_hash = NULL`
  - `edge_last_heartbeat_at = NULL`
  - `edge_reported_config_hash = NULL`
  - `edge_agent_version = NULL`
- на ноде остановлены/отключены edge unit'ы:
  - `grani-edge-heartbeat.timer/.service`
  - `grani-edge-poll.timer/.service`
- проверка после переключения:
  - `xray-v2 = active`
  - `xray = inactive`

Практический эффект:
- backend больше не ставит apply в edge assignment для этой ноды;
- применяется старый путь через SSH (`sync_ssh`/celery apply), который исторически был стабильнее на проекте;
- исключается отдельный класс edge-loop проблем (`pending/defer/assignment churn`) для HU-BUD-01.

## Контрольный прогон после rollback на SSH rails (2026-05-08, выполнено)

Запуск:
- `PYTHONPATH=/opt/grani/backend python3 backend/scripts/diagnostics_hu_bud_client_ip_window.py --server-name HU-BUD-01 --client-ip 94.180.243.40 --window-sec 90 --interval-sec 5`

Фактический результат:
- в live-окне снова наблюдается массивный churn на `:4443`: тысячи состояний `ESTAB`/`FIN-WAIT-1` (по выгрузке: `ESTAB` ~5073, `FIN-WAIT-1` ~5073);
- для `FIN-WAIT-1` повторяется тот же паттерн `unacked=1 retrans=1 lost=1`;
- tail `xray error.log` содержит плотную серию `read tcp 45.12.132.94:4443->94.180.243.40:*: i/o timeout` (по окну ~80 событий);
- switch на SSH rails убрал edge-loop класс проблем, но не устранил transport-деградацию на baseline `vless@4443`.

Вывод:
- проблема первично не в edge-agent как механизме apply, а в data-plane профиле `:4443` под heavy/churn трафиком;
- rollback на SSH rails полезен как стабилизация control-plane, но для интернет-качества требуется дальнейшее смещение нагрузки с `vless@4443` и/или полное отключение heavy-path на этом inbound.

## Анти-пустые тесты: принятый план и выполнение (2026-05-08)

Принцип на этот цикл:
- не делать дополнительные "гипотезы поверх гипотез";
- собрать диагностический APK с максимально "чистым" одно-туннельным runtime-path;
- исключить влияние split tunnel и агрессивных routing-инъекций как побочных факторов.

Выполнено в коде:
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/SplitTunnelHelper.kt`
  - добавлен `FORCE_DISABLE_SPLIT_TUNNEL=true` (app-based split tunnel принудительно отключен для диагностической сборки).
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt`
  - добавлен `FORCE_NEUTRAL_SPLIT_DOMAINS=true` (user direct-domains из prefs не применяются в routing JSON в диагностическом режиме).
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayRoutingHelper.kt`
  - добавлен `DIAG_MINIMAL_ROUTING_MODE=true`;
  - в minimal mode отключены побочные routing-модификации:
    - speedtest-specific outbound/rules,
    - single-port/reality strict routing coercion,
    - публичные DNS direct injections,
    - QUIC-block injections;
  - оставлен только минимальный control-plane bypass (`CONTROL_PLANE_API_DOMAINS`/`CONTROL_PLANE_API_IPS`).

Что это дает:
- следующий прогон сравнивает именно базовый data-plane путь, а не смесь побочных клиентских политик;
- если деградация `:4443` сохранится и в таком "чистом" режиме, причина окончательно закрепляется за node transport path.

## Контрольный логкат-прогон clean tunnel (2026-05-08 15:09-15:10)

Источник: логкат пользователя после установки диагностического APK.

Подтверждено по факту:
- clean-mode реально активирован на клиенте:
  - `buildProcessedXrayConfig: split_tunnel mode=exclude apps=0 direct_domains=0`;
  - `applyFullVpnRouting: minimal mode enabled (skip ... injections)`;
  - `Split tunnel: force-disabled for diagnostic build`.
- dataplane поднимается штатно:
  - `serviceState=DATAPLANE_VERIFIED` -> `serviceState=COMMITTED`;
  - `[CONNECTIVITY_PROBE] ... public_internet ok=true`.
- трафик в tunnel действительно идет:
  - множественные `proxy/vless/outbound ... via 45.12.132.94:4443`;
  - есть обращения к `www.speedtest.net`, `mapi.speedtest.net`, `youtubei.googleapis.com`, `redirector.googlevideo.com` через `proxy`.

Что важно:
- в этом фрагменте нет явного client-side краша pipeline (нет rollback из COMMITTED по ошибке);
- остановка в конце — пользовательский disconnect (`reason=user_disconnect`);
- `tun2socks ... connection failed` после STOP — ожидаемые хвостовые ошибки teardown, не root cause деградации data-plane.

Ограничение этого прогона:
- логкат подтверждает правильный клиентский маршрут и факт проксирования, но не дает node-side quality-метрики (RTT/retrans/FIN-WAIT/i/o timeout density) в этом же окне;
- для финального verdict по деградации `:4443` нужен синхронный node-диагностический срез на тот же временной интервал.

## Синхронный node-срез после clean-tunnel прогона (2026-05-08 12:12-12:14 UTC)

Команда:
- `PYTHONPATH=/opt/grani/backend:/opt/grani/backend/scripts python3 backend/scripts/diagnostics_hu_bud_client_ip_window.py --server-name HU-BUD-01 --client-ip 94.180.243.40 --window-sec 90 --interval-sec 5`

Результат:
- устойчиво наблюдается churn на `:4443`:
  - `FIN-WAIT-1`: ~781 строк;
  - `ESTAB`: ~1722 строки;
  - в `FIN-WAIT-1` повторяется сигнатура `unacked=1 retrans=1/9 lost=1`.
- `xray error.log` в том же окне: ~79 событий `read tcp 45.12.132.94:4443->94.180.243.40:*: i/o timeout`.

Вывод:
- даже при подтвержденном clean-tunnel на клиенте (без split/speedtest/single-port/quic инъекций) деградация на baseline `vless@4443` сохраняется;
- root cause закрепляется за node data-plane на `:4443`, а не за клиентским routing-пайплайном.

## Попытка совместимого firewall-контура (2026-05-08, после синхронного среза)

Что проверено на ноде HU-BUD-01:
- `nft` отсутствует (`nft command not found`);
- `firewalld` отсутствует в runtime (`inactive`);
- доступны `ufw` и `iptables`.

Что применено как рабочий fallback:
- через `backend/scripts/apply_hu_bud_nft_guard.py` выполнен fallback на iptables-only churn guard:
  - `XRAYV2_GUARD`: `80/sec burst 160` для `--syn` на `2053/8443/4443`;
  - `XRAYV2_4443_CHURN_GUARD`: ужесточено до `15/sec burst 30` для `--syn` на `:4443`.

Статус:
- guard применен успешно (цепочки и правила подтверждены `iptables -S` на ноде);
- следующий шаг: один контрольный пользовательский прогон (Speedtest + YouTube) под синхронный node-срез.

## Проверка после fallback guard (2026-05-08 12:21-12:23 UTC)

Команда:
- `PYTHONPATH=/opt/grani/backend:/opt/grani/backend/scripts python3 backend/scripts/diagnostics_hu_bud_client_ip_window.py --server-name HU-BUD-01 --client-ip 94.180.243.40 --window-sec 90 --interval-sec 5`

Метрики окна:
- `FIN-WAIT-1`: ~3184 (было ~781 в предыдущем clean-tunnel срезе);
- `ESTAB`: ~1218 (было ~1722);
- `i/o timeout`: ~80 (по плотности сопоставимо с предыдущим окном ~79).

Интерпретация:
- ужесточенный `iptables` SYN-guard (`15/sec burst 30` на `:4443`) не устранил transport-деградацию;
- по соотношению состояний (`FIN-WAIT-1` заметно выше `ESTAB`) поведение стало хуже под тем же пользовательским сценарием;
- root cause остается в data-plane `vless@4443` (не в клиентском clean-tunnel роутинге).

## Интеграция нового сервера (UK-LON-01) — 2026-05-08

Выполнено:
- удален пользовательский скрин с чувствительными данными из workspace assets;
- в БД создан сервер `UK-LON-01` (`id=3`, `ip=45.140.167.123`, `ssh_user=root`, `domain=vm5101453.example.com`);
- SSH-доступ проверен через `RemoteVPNManager`: подключение успешно;
- на ноде установлен `xray` (v26.3.27) и развернут `xray-v2` systemd runtime;
- применена базовая Xray-конфигурация (VLESS `4443`, VMESS `8443`, dokodemo `10085`) + REALITY;
- исправлен блокер нового формата `xray x25519` (в логе выводится `Password (PublicKey)`): в server-side config оставлен корректный `privateKey`, `publicKey` удален из inbound realitySettings;
- статус после фикса: `xray-v2 active`, сокеты слушают `:4443`, `:8443`, `:10085`.

Важно по безопасности:
- текущий SSH пароль использован как временный bootstrap-канал;
- следующий обязательный шаг: перейти на SSH-ключ и удалить пароль из `servers.ssh_password`.

## Точечный mismatch-fix backend->node для UK-LON-01 (2026-05-08)

Что проверено в связке:
- server `UK-LON-01 (id=3)` в БД: `reality_enabled=true`, `xray_port=2053`, `supported_protocols` включает `xray_vless` и `xray_reality`;
- фактический runtime-конфиг на ноде:
  - `vless+reality` слушает `:4443`,
  - plain `vless+none` слушает `:4444`.

Root cause mismatch:
- backend генератор клиентского `json_config` (`_generate_client_json_config`) для plain `vless` брал статический default-порт (`4443`) вместо фактического runtime inbound;
- в результате мобильный клиент получал `security=none + port=4443` и пытался идти plain VLESS в reality inbound (`connection reset by peer` / handshake mismatch).

Что исправлено в коде:
- `backend/infrastructure/external/xray_manager.py`:
  - добавлен `_resolve_port_from_runtime_inbound(server, protocol_kind, security)`;
  - в `_generate_client_json_config` порт теперь резолвится из фактического inbound в cached runtime config, а не из статического дефолта.

Быстрая проверка после фикса:
- для `server_id=3` генерация дает:
  - plain `vless` -> `port=4444`, `tls=none`;
  - `reality` -> `port=4443`, `tls=reality`.

Ожидаемый эффект:
- исключается отправка plain VLESS на reality-порт и класс ошибок `failed to decode response header / connection reset by peer` по причине backend->node port/security mismatch.

## UK-LON-01 повторный логкат и усиление фикса (2026-05-08)

Новый логкат показал:
- клиент по-прежнему получает `XRAY_OUTBOUND_DIAG ... security=none ... port=4443`;
- после этого массово повторяется `failed to decode response header ... connection reset by peer`.

Вывод:
- в части connect-запросов генерация JSON шла без прогретого config-cache и брала default-порт.

Усиление фикса:
- в `backend/infrastructure/external/xray_manager.py` обновлен `_resolve_port_from_runtime_inbound`:
  - если cache пуст, backend теперь принудительно читает реальный `config.json` ноды через SSH,
  - сохраняет его в cache,
  - и только после этого резолвит порт inbound по `(protocol_kind, security)`.

Проверка фикса:
- при принудительно пустом cache (`_get_cached_xray_config -> None`) генерация дает:
  - plain `vless`: `port=4444`, `tls=none`;
  - `reality`: `port=4443`, `tls=reality`.

## Ретест после усиления фикса (2026-05-08, 16:25 local logcat)

Подтверждено по логу:
- `XRAY_OUTBOUND_DIAG` теперь корректный: `security=reality`, `serverName=google.com`, `shortId_len=16`, `publicKey_sha=...`;
- `XRAY_EFFECTIVE_OUTBOUNDS` также показывает `proxy/vless/45.140.167.123:4443/reality`;
- массовых `connection reset by peer`/`failed to decode response header` в этом прогоне не видно.

Новый обнаруженный узел:
- первая попытка `/v2/vpn/xray/connect` уходит в `receiveTimeout` на 12s, затем только на attempt#2 приходит успешный ответ;
- итоговый connect заметно растягивается (`xray_fetch_config_done fetch_ms ~17464`, total ~21s), что субъективно воспринимается как провал.

Сделано:
- `mobile-app/lib/services/xray_connection_handler.dart`:
  - увеличен first-attempt cap таймаутов в `_shrinkFirstAttemptTimeout` с `12s` до `20s` (connect/receive),
  - чтобы сократить ложные transport-retry на медленном cold-path.

## Логкат 2026-05-08 16:48-16:50 (UK-LON-01) и следующий точечный фикс

Подтверждено по свежему логкату:
- control-plane и connect-stage проходят корректно (`Google OAuth OK`, `/v2/vpn/xray/connect` за ~1.1s, `COMMITTED`);
- effective outbound корректный и стабильный: `proxy/vless/45.140.167.123:4443/reality`;
- root-cause в data-plane после commit: массовые циклы `transport/internet/tcp: dialing ...:4443` и затем
  `proxy/vless/outbound: failed to find an available destination > ... operation was canceled / i/o timeout`;
- одновременно видно деградацию UDP-пути (`transport/internet/udp: ... read/write on closed pipe`) с последующим retry-штормом в TCP на тот же `:4443`.

Интерпретация:
- это не проблема авторизации и не mismatch-конфига клиента;
- это runtime-деградация transport path Reality при churn-нагрузке (особенно при XUDP/UDP burst), которая валит доступность апстрима `:4443`.

Сделано (точечный стабилизационный шаг):
- выключен `packetEncoding = xudp` для Reality-клиента (оставлен plain TCP framing) в:
  - `mobile-app/lib/protocols/xray/models/xray_config.dart`
  - `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayConfig.kt`

Ожидаемый эффект:
- убрать каскад `udp closed pipe -> tcp redial storm` и снизить частоту `operation was canceled` на `45.140.167.123:4443`;
- получить более ровный dataplane под тем же пользовательским сценарием (YouTube/Speedtest/Instagram).

## Логкат 2026-05-08 17:08-17:10 (UK-LON-01) — pinpoint root cause и фиксация маршрутизации

Что подтвердилось по новому логу:
- VPN поднимается корректно: `DATAPLANE_VERIFIED -> COMMITTED`, `CONNECTIVITY_PROBE ok=true`, есть реальный трафик (`[VPN_TRAFFIC] rx/tx`).
- До деградации виден стабильный выход в `proxy/vless/45.140.167.123:4443/reality`.
- Затем повторяется тот же паттерн деградации:
  - массовые UDP/443 сессии через `proxy` (`accepted udp:...:443 [socks-in -> proxy]`);
  - `transport/internet/udp: ... read/write on closed pipe`;
  - каскадный redial в TCP `dialing ... 45.140.167.123:4443`;
  - `failed to find an available destination ... operation was canceled`.

Новый точный вывод по коду:
- в Android routing helper был включен диагностический early-return:
  - `DIAG_MINIMAL_ROUTING_MODE = true` в `XrayRoutingHelper`;
  - из-за этого не применялись критические стабилизирующие инъекции (`single-port/quic-block/policy`), несмотря на наличие кода.
- одновременно `GLOBAL_UDP_443_BLOCK_ENABLED = false`, то есть глобальный QUIC/UDP443-block был выключен.

Что изменено сейчас:
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayRoutingHelper.kt`:
  - `DIAG_MINIMAL_ROUTING_MODE: true -> false` (убран early-return диагностического режима);
  - `GLOBAL_UDP_443_BLOCK_ENABLED: false -> true` (включен глобальный блок UDP/443 через `blackhole`).

Ожидаемый эффект:
- убрать UDP/443 churn в прокси, который разваливает TCP path на `:4443`;
- стабилизировать VLESS/Reality data-plane под heavy-сценарием (Speedtest/YouTube/Instagram);
- сохранить full-tunnel behavior без split-tunnel факторов.

## Логкат 2026-05-08 17:24-17:26 (UK-LON-01) — новый pinpoint: UDP loop на границе tun2socks

Что подтверждено по свежему логу:
- `COMMITTED` достигается стабильно, `CONNECTIVITY_PROBE ok=true`, есть `VPN_TRAFFIC` — туннель поднимается и не падает сразу.
- Правило QUIC-block реально применяется (`[socks-in -> blocked]` для множества `udp:*:443`).
- Но при этом сохраняется интенсивный цикл:
  - `transport/internet/udp: establishing new connection for udp:*:443`
  - `... taking detour [blocked]`
  - `... failed to handle UDP input > io: read/write on closed pipe`
  - повтор сотни раз в минуту.
- Ключевой маркер в логе: `Tun2SocksProc [UDP_GUARD] ... enabled=false forward_udp=true`.

Новый вывод:
- даже при блокировке UDP/443 на уровне Xray routing, сам поток UDP продолжает массово попадать в socks-in из `tun2socks`;
- это создает постоянный redial/closed-pipe storm и забивает dataplane (CPU/queue pressure), из-за чего пользовательский TCP-path воспринимается как «VPN есть, интернета нет/тормозит».

Что изменено сейчас (точечно):
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/Tun2SocksProcessService.kt`:
  - `GLOBAL_UDP_REDIAL_GUARD_ENABLED: false -> true`;
  - итогово `forward_udp=false` на границе `tun2socks`.

Ожидаемый эффект фикса:
- остановить источник UDP/443 retry-storm до попадания в Xray;
- резко снизить spam `udp closed pipe` в GoLog;
- освободить dataplane для стабильного TCP-трафика (Speedtest/YouTube/Instagram через proxy TCP).

### Фиксация для последнего APK (собран после этого изменения)

Состав последнего APK:
- включен guard на границе `tun2socks` (UDP redial guard):
  - файл: `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/Tun2SocksProcessService.kt`
  - изменение: `GLOBAL_UDP_REDIAL_GUARD_ENABLED=true` -> `forward_udp=false`.

Что обязательно проверить в следующем логкате после установки APK:
- маркер процесса `Tun2SocksProc`:  
  `[UDP_GUARD] marker=udp_redial_guard_v1_2026_05_08 enabled=true forward_udp=false`
- ожидаемое поведение:
  - существенное снижение/исчезновение циклов `transport/internet/udp ... closed pipe`;
  - сохранение `COMMITTED`;
  - пользовательский TCP-трафик (YouTube/Speedtest) проходит стабильнее.

## Логкат 2026-05-08 17:47-17:49 (UK-LON-01) — pinpoint: client self-disconnect после COMMITTED

Что подтверждено по свежему логу:
- туннель реально поднимается:
  - `serviceState=COMMITTED`;
  - `[CONNECTIVITY_PROBE] ... status=ok_dataplane_control_plane_degraded public_internet ok=true`.
- сразу после этого connect pipeline помечается как failed:
  - `stage=stage_error ... fail_code=connect_fail_stage_apply_protocol__exception`;
  - затем принудительный `disconnect` с источником `connectivity_commit_gate:commit_failed_no_traffic`.
- это не падение Xray/туннеля на старте, а авто-отключение со стороны client commit-gate.

Root cause:
- commit-gate в `VpnService` допускал hard-abort даже при `public_internet ok=true`, если API probe (`api.granilink.com`) временно деградировал по DNS (`UnknownHostException`) и трафик еще не успел быть зафиксирован как `traffic_seen`.
- в результате рабочий dataplane ошибочно считался failed и VPN отключался самим приложением.

Что изменено сейчас (точечно, 1 гипотеза = 1 фикс):
- `mobile-app/lib/services/vpn_service.dart`:
  - в `_shouldAbortStrictConnectivityCommit()` добавлен guard: **не abort-ить commit, если `public_ok=true`**;
  - в `_maybeFinalizePostConnectCommit()` добавлена ветка degraded для случая **`public_ok=true` + `api_ok=false`** (вместо disconnect).

Ожидаемый эффект:
- убрать ложный self-disconnect сразу после `COMMITTED`;
- при временной деградации DNS/control-plane держать VPN в `connected` и помечать состояние как degraded;
- дать туннелю время на нормальный user traffic без отстрела по commit-gate.

## Анализ окна 2026-05-08 15:06-15:08 UTC (session `1778252797081_9db`, UK-LON-01)

Что подтверждено корреляцией backend+node:
- сессия клиента реально идет на `server_id=3` (UK-LON-01), pipeline доходит до `COMMITTED`, есть `traffic_first_seen`;
- backend `/v2/vpn/xray/connect` отвечает быстро (порядка 55-100ms), критичных backend-ошибок в окне нет;
- на ноде `UK-LON-01` в `config-v2.json` у inbound `vless@4443` был включен `tcpSettings.acceptProxyProtocol=true`;
- при этом в `access.log` нет нормальных accepted-записей по клиентской сессии (виден в основном внешний шум/скан на `vmess@8443`).

Root cause (server-side):
- `acceptProxyProtocol=true` на прямом клиентском входе `:4443` заставляет Xray ждать PROXY header.
- Мобильный клиент подключается напрямую к IP ноды и PROXY header не отправляет.
- Итог: data-plane нестабилен/пустой с симптомом «VPN подключен, но Speedtest/YouTube не открываются».

Что сделано сразу:
- На ноде `UK-LON-01` в `/usr/local/etc/xray/config-v2.json` применено:
  - `inbound vless@4443 -> tcpSettings.acceptProxyProtocol=false`;
  - выполнен `systemctl reload xray-v2` (статус `active`).

Чтобы фикс не откатывался при последующих apply:
- `backend/infrastructure/external/xray_manager.py`:
  - при создании inbound по умолчанию `acceptProxyProtocol=false`;
  - в transport-tuning default для `vless@4443` также `acceptProxyProtocol=false`.
- `backend/services/xray_provisioning_service.py`:
  - базовый `vless-in` создается с `acceptProxyProtocol=false`.

## 2026-05-08 — reference routing profile (минимальная схема без доп. мутаций)

Цель:
- убрать дополнительные routing-модификации на клиенте и проверить "чистый" профиль Xray:
  - базовый `socks-in -> proxy`;
  - исключения `direct` для VPN server и DNS;
  - обязательный `control-plane direct` (через `XrayRoutingHelper`).

Что изменено:
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayRoutingHelper.kt`
  - `DIAG_MINIMAL_ROUTING_MODE=true`.
  - Эффект: `applyFullVpnRouting()` выполняет только mandatory bypass (API domains/IPs) и **не** применяет:
    - `enforceSingleProxyPort`,
    - `injectQuicBlockRules`,
    - speedtest-specific outbound/rules,
    - policy-тюнинг.

Сборка:
- выполнена сборка `flutter build apk --release` (успешно).
- артефакт: `mobile-app/build/app/outputs/flutter-apk/app-release.apk`.

## 2026-05-08 18:56-19:00 UTC — чистый прогон + server-side точечный фикс (UK-LON-01)

Что подтвердил клиентский лог (чистый прогон):
- VPN проходит полный pipeline до `COMMITTED` (`session=1778255795749_35f4`), `public_internet ok=true`.
- Трафик YouTube/Google реально идет через `socks-in -> proxy` и далее в `45.140.167.123:4443` (много `dialing TCP to tcp:45.140.167.123:4443`).
- Явных `connection reset by peer` и старого `udp closed pipe`-шторма в активной фазе нет.

Что найдено по ноде `UK-LON-01`:
- `xray-v2` работал с `config-v2.json`, но на ноде был открыт дополнительный inbound `vmess@8443`.
- `access.log` забит внешним скан-шумом именно по `:8443` (`invalid user`, `i/o timeout`, `connection reset by peer`), полезного клиентского трафика там нет.
- На момент среза это создавало постоянную лишнюю нагрузку/шум на процесс Xray, не относящуюся к реальному клиенту.

Что сделано сразу:
- На ноде удален inbound `vmess@8443` из `/usr/local/etc/xray/config-v2.json`, оставлены только:
  - `vless-in@4443` (Reality/TCP, `acceptProxyProtocol=false`);
  - `stats-api@10085`.
- Выполнен `systemctl restart xray-v2` (важно: `ExecReload` в unit делает только `-test`, не применяет runtime-конфиг).
- После рестарта проверено:
  - слушаются только `:4443` и `:10085`;
  - `:8443` больше не слушается.

Ожидаемый эффект:
- убрать постоянный внешний VMess-шум, который отвлекал процесс Xray;
- снизить паразитную деградацию на ноде под пользовательской нагрузкой;
- оставить только целевой транспорт для клиента (`Reality :4443`).


## Обновление 2026-05-12 (live-анализ YouTube после авторизации, UK-LON-01)

Сценарий пользователя:
- пользователь заново прошел авторизацию, подключился к VPN и открыл YouTube;
- симптом сохранился: VPN подключен, но видео YouTube не открываются.

Что подтверждено live-корреляцией:
- backend connect проходит на server_id=3 (UK-LON-01), protocol=xray_reality, traffic_profile=throughput;
- POST /api/v2/vpn/xray/connect отвечает 200;
- apply-state все еще возвращает is_applied=False и long-poll timeout, но это не primary root-cause для YouTube;
- Xray на UK-LON-01 после restart работает со свежим config-v2.json;
- runtime слушает только :4443 и :10085, старый шумный :8443 не поднят;
- новых localhost:80 fallback ошибок после restart не появляется;
- в access.log есть accepted-трафик от текущего IP пользователя 94.180.243.40 для других приложений/доменов, значит туннель не полностью мертв;
- YouTube-домены почти не доходят до access.log, при этом на node-срезах остается churn FIN-WAIT-1/lost:1 на :4443.

Найденный новый клиентский блокер:
- текущий APK был собран с GLOBAL_UDP_REDIAL_GUARD_ENABLED=true;
- фактический режим tun2socks: forward_udp=false;
- для YouTube это критично, потому что YouTube активно стартует через UDP/QUIC, а UDP отрезался на границе tun2socks еще до Xray;
- из-за этого Xray/нода видят не полноценный YouTube-flow, а в основном TCP-хвосты и трафик других приложений.

Что сделано 2026-05-12:
- на UK-LON-01 закреплен net.ipv4.tcp_congestion_control=bbr;
- добавлен persistent sysctl-файл /etc/sysctl.d/99-grani-xray-transport.conf;
- для xray-v2 добавлен drop-in /etc/systemd/system/xray-v2.service.d/10-reload-failsafe.conf, чтобы ExecReload больше не делал только xray -test без применения конфига;
- xray-v2 был перезапущен, процесс свежий и активный;
- в mobile диагностически изменен Tun2SocksProcessService.kt: GLOBAL_UDP_REDIAL_GUARD_ENABLED=false, итоговый ожидаемый режим forward_udp=true;
- собран новый release APK (arm64), размер около 86.9MB;
- APK выложен в стандартный download-путь: https://api.granilink.com/downloads/app-release.apk.

Что обязательно проверить в следующем logcat после установки нового APK:
- маркер новой сборки: [UDP_GUARD] marker=udp_redial_guard_v1_2026_05_08 enabled=false forward_udp=true;
- VPN должен подключиться к UK-LON-01 / 45.140.167.123:4443 / reality;
- YouTube должен либо начать отдавать видео, либо в логах должен появиться новый конкретный transport-паттерн (например UDP closed-pipe storm уже внутри Xray);
- если появится UDP storm, следующий фикс делать точечно в QUIC handling/routing, а не снова отключать весь UDP на границе tun2socks.

Ссылка для установки текущего диагностического APK:
- https://api.granilink.com/downloads/app-release.apk

- Рабочая ссылка без Cloudflare-кэша 404: https://api.granilink.com/downloads/grani-vpn-20260512-udp.apk
- Альтернативная ссылка с cache-busting: https://api.granilink.com/downloads/app-release.apk?v=20260512-udp

## Обновление 2026-05-12 12:07 MSK — следующий диагностический APK после белого экрана YouTube

Сценарий пользователя:
- пользователь установил APK с forward_udp=true, подключился к VPN и открыл YouTube;
- результат: YouTube показывает белый экран, проблема сохраняется.

Live-вывод после этого прогона:
- backend connect успешен: /api/v2/vpn/xray/connect возвращает 200 для server_id=3 (UK-LON-01), device_id=e786a3d4-71fa-4bef-ac9e-68ce9c7e7d41;
- на UK-LON-01 туннель не полностью мертв: в access.log в окне теста виден accepted-трафик от IP пользователя 94.180.243.40 к другим приложениям/доменам;
- YouTube/Googlevideo почти не доходят до server access log, значит проблема вероятнее остается на клиентской стороне routing/UDP/QUIC до полноценного выхода в Xray node;
- после APK с forward_udp=true в коде все еще был активен GLOBAL_UDP_443_BLOCK_ENABLED=true, то есть UDP уже проходил в tun2socks, но клиентский Xray локально blackhole-ил UDP/443 (QUIC).

Следующий точечный тест:
- оставить GLOBAL_UDP_REDIAL_GUARD_ENABLED=false в Tun2SocksProcessService.kt, то есть forward_udp=true;
- отключить GLOBAL_UDP_443_BLOCK_ENABLED=false в XrayRoutingHelper.kt;
- DIAG_MINIMAL_ROUTING_MODE=true оставить включенным;
- xudp/packetEncoding не включать, чтобы в одном тесте проверить только влияние локального QUIC blackhole.

Что изменено и собрано:
- mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayRoutingHelper.kt: GLOBAL_UDP_443_BLOCK_ENABLED=false;
- flutter build apk --release --target-platform android-arm64 выполнен успешно;
- APK опубликован как уникальный файл без CDN 404-кэша.

Ссылка на APK для следующего теста:
- https://api.granilink.com/downloads/grani-vpn-20260512-udp-open.apk

Контрольные маркеры в logcat после установки:
- [UDP_GUARD] marker=udp_redial_guard_v1_2026_05_08 enabled=false forward_udp=true;
- injectQuicBlockRules: disabled (GLOBAL_UDP_443_BLOCK_ENABLED=false) marker=quic_block_forced_v2_2026_05_08.

Интерпретация результата:
- если YouTube оживет, root cause — слишком грубый локальный QUIC block; дальше нужно заменить его на более аккуратную политику, а не возвращать глобальный UDP ban;
- если YouTube останется белым и появится UDP closed-pipe/transport storm, следующий фикс делать в UDP transport handling или selective routing;
- если YouTube останется белым без UDP storm, нужен свежий logcat именно с этим APK и маркерами выше, чтобы увидеть, куда пропадают YouTube flows до access.log.

## Обновление 2026-05-12 12:24 MSK — расследование белого экрана после udp-open APK, backend-first

Сценарий пользователя:
- установлен APK grani-vpn-20260512-udp-open.apk;
- VPN подключен, открыт YouTube;
- симптом: белый экран сохраняется.

Logcat-факты из OnePlus-MT2111-Android-14_2026-05-12_121548.logcat:
- connect прошел до COMMITTED;
- в клиентском Xray есть YouTube flows:
  - youtubei.googleapis.com -> proxy -> tcp:216.239.34.223:443;
  - i.ytimg.com -> proxy -> tcp:209.85.233.119:443;
  - redirector.googlevideo.com -> proxy -> tcp:74.125.205.198:443;
- UDP/443 теперь реально включен и идет через proxy:
  - accepted udp:216.239.34.223:443;
  - accepted udp:209.85.233.119:443;
  - accepted udp:74.125.205.198:443;
- счетчики в logcat:
  - accepted udp: 7;
  - accepted tcp: 29;
  - transport/internet/udp: 7;
  - udp closed pipe: 0;
  - failed to read response header: 0;
  - connection reset: 0.

Server/node факты UK-LON-01:
- backend connect 2026-05-12 09:15:17 UTC успешен, server_id=3, status=200, но занял около 5.3s;
- Xray node active;
- на node access.log появились YouTube/QUIC записи от IP пользователя 94.180.243.40:
  - accepted tcp:youtubei.googleapis.com:443;
  - accepted udp:216.239.34.223:443;
- это значит, предыдущая гипотеза про локальный QUIC blackhole больше не primary blocker: UDP и TCP доходят до node.

Новый главный симптом:
- на UK-LON-01 по client IP 94.180.243.40 наблюдается массовый хвост TCP-сокетов к :4443:
  - примерно ESTAB 33-53;
  - FIN-WAIT-1 600+;
  - почти все FIN-WAIT-1 имеют lost:1/retrans и backoff;
  - MSS деградирует до 256/128/64 при pmtu 1388;
- это похоже на проблему обратного TCP path/PMTU/packet loss между UK-LON-01 и текущим клиентским IP, а не на падение Xray-клиента.

Backend-only тест без новой сборки:
- на UK-LON-01 временно изменен route MTU для текущего IP пользователя:
  - было: ip route get 94.180.243.40 -> cache mtu 1388;
  - стало: ip route replace 94.180.243.40 via 45.140.167.1 dev ens3 src 45.140.167.123 mtu 1200;
  - после применения: ip route get 94.180.243.40 -> cache mtu 1200;
- tcp_metrics для IP пользователя удален;
- sysctl подтвержден:
  - net.ipv4.tcp_mtu_probing=1;
  - net.ipv4.tcp_congestion_control=bbr.

Следующий тест для пользователя:
- переподключить VPN, чтобы новые Reality TCP-сессии пошли уже через route mtu 1200;
- открыть YouTube заново;
- если YouTube оживет или начнет грузить дальше белого экрана, root cause близко к PMTU/return-path;
- если не оживет, собрать свежий logcat после переподключения и сравнить количество FIN-WAIT-1/lost на node после MTU 1200.

## Обновление 2026-05-12 12:36 MSK — текущий белый экран после корректного прогона, backend-only

Сценарий:
- пользователь подключился к VPN, открыл YouTube, снова белый экран;
- logcat: OnePlus-MT2111-Android-14_2026-05-12_122916.logcat;
- пользователь в момент анализа находился в YouTube.

Logcat-факты:
- сборка подтверждена: [UDP_GUARD] marker=udp_redial_guard_v1_2026_05_08 enabled=false forward_udp=true;
- client Xray ошибок transport нет:
  - udp closed: 0;
  - closed pipe: 0;
  - failed to read response header: 0;
  - connection reset: 0;
  - i/o timeout: 0;
- YouTube/Googlevideo flows есть на клиенте:
  - youtubei.googleapis.com: 6;
  - redirector.googlevideo.com/googlevideo: 12;
  - ytimg: 2;
  - accepted udp: 13;
  - accepted tcp: 34;
- YouTube media идет через proxy, DNS/DoT часто идет direct к 1.1.1.1/9.9.9.9.

Backend/node факты:
- backend connect на UK-LON-01 быстрый: 2026-05-12 09:28:53 UTC, status=200, около 70ms;
- apply-state по-прежнему is_applied=False, но connect и client dataplane стартуют;
- на UK-LON-01 после route MTU 1200 все еще видны массовые FIN-WAIT-1/lost/retrans по IP пользователя;
- access.log UK в текущем окне почти не показывает свежие YouTube entries, хотя клиентские Xray logs показывают socks-in -> proxy для YouTube;
- это усиливает гипотезу transport/return-path на UK-LON-01, а не client Xray crash.

Backend-only действия:
- MTU для текущего IP пользователя на UK-LON-01 был снижен только для route к 94.180.243.40:
  - было cache mtu 1200;
  - стало cache mtu 1000;
  - команда: ip route replace 94.180.243.40 via 45.140.167.1 dev ens3 src 45.140.167.123 mtu 1000;
  - ip tcp_metrics delete 94.180.243.40 выполнен;
  - tcp_mtu_probing=1, tcp_congestion_control=bbr.

Следующие backend-first тесты:
1. Попросить пользователя закрыть YouTube из recent apps и открыть заново; лучше — переподключить VPN, чтобы новые TCP-сессии пошли с MTU 1000.
2. Если MTU 1000 не помогает, сделать A/B на HU-BUD-01 без сборки:
   - вариант безопаснее: пользователь вручную выбирает HU-BUD-01 в приложении, если UI позволяет;
   - вариант backend-only с влиянием на список серверов: временно убрать UK-LON-01 из active servers и сбросить server-list cache, чтобы приложение выбрало HU-BUD-01. Делать только после подтверждения пользователя, потому что это влияет на общий список серверов.

## Обновление 2026-05-12 12:40 MSK — уточнение по logcat [socks-in -> proxy] и следующий A/B

Уточнение по гипотезе пользователя:
- в logcat Xray записи вида [socks-in -> proxy] не означают внешний HTTP/SOCKS-прокси поверх VLESS;
- proxy — это обычный outbound tag внутри локального Xray-конфига клиента;
- нормальная цепочка для текущего клиента:
  - YouTube app -> tun2socks -> local Xray socks-in -> outbound tag proxy -> VLESS Reality -> selected node;
- поэтому само наличие [socks-in -> proxy] не является нарушением классического VLESS/Reality поведения.

Что остается релевантным:
- transport/protocol profile все еще может быть причиной симптома, потому что YouTube создает много коротких TCP/UDP/QUIC flows;
- на UK-LON-01 эти flows коррелируют с массовыми FIN-WAIT-1/lost/retrans на Reality TCP endpoint;
- это больше похоже на path/transport issue, чем на неправильное использование слова proxy в Xray logs.

Следующий тест без сборки:
- пользователь готов подключаться к любому серверу;
- первым тестировать HU-BUD-01 как чистый A/B против UK-LON-01;
- если в приложении доступен ручной выбор сервера, выбрать HU-BUD-01, подключиться, открыть YouTube и сообщить результат;
- если ручного выбора нет или клиент снова уходит на UK-LON-01, тогда временно backend-only убрать UK-LON-01 из активного списка и сбросить cache:servers:list, но только после подтверждения, потому что это влияет на общий список серверов.

## Обновление 2026-05-12 12:52 MSK — HU/UK live A/B и следующая backend-only гипотеза

Пользователь последовательно подключился к HU-BUD-01 и UK-LON-01, открыл YouTube; на обоих серверах пользовательский симптом сохраняется: белый экран, без стабильной прогрузки видео.

Факты live-среза:
- HU-BUD-01: backend connect прошел на server_id=1, клиентский effective_outbounds=proxy/vless/45.12.132.94:2053/reality; первичный public/API probe проходил, затем клиент фиксировал connected_degraded_retry с причиной commit_window_expired_public_probe_failed_proxy_tunneling_seen.
- UK-LON-01: backend connect прошел на server_id=3, клиентский effective_outbounds=proxy/vless/45.140.167.123:4443/reality; первичный public/API probe проходил, затем снова connected_degraded_retry.
- UK node diagnostics во время YouTube: много TCP-сокетов :4443 -> 94.180.243.40 в FIN-WAIT-1 с retrans/lost, даже после per-IP route MTU 1000 и включенного BBR/MTU probing. Это подтверждает деградацию transport path под реальной нагрузкой, а не полный fail connect.
- HU/UK A/B показывает, что проблема не сводится к одному серверу. Нужно тестировать общий профиль трафика/Reality/VLESS/UDP, без новой APK-сборки.

Следующая backend-only гипотеза для теста:
- временно запретить QUIC/UDP-443 на серверной стороне UK-LON-01, чтобы YouTube был вынужден перейти на TCP внутри уже поднятого туннеля;
- тест должен быть обратимым и коротким, с фиксацией команды и результата в этом файле;
- применять только после явного подтверждения пользователя, так как правило на ноде может затронуть общий UDP/443-трафик через UK.

## Обновление 2026-05-12 12:58 MSK — применен backend-only QUIC/UDP-443 test на UK

После подтверждения пользователя применен временный серверный A/B-тест на UK-LON-01:
- цель: проверить, зависает ли YouTube на QUIC/UDP-443 при рабочем Reality TCP-туннеле;
- действие: на UK-LON-01 добавлено правило iptables OUTPUT, которое отклоняет исходящий UDP на destination port 443;
- команда на ноде: iptables -I OUTPUT 1 -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable;
- проверка: iptables -S OUTPUT показывает правило -A OUTPUT -p udp -m udp --dport 443 -j REJECT --reject-with icmp-port-unreachable.

Инструкция для теста пользователя:
- переподключить VPN на UK-LON-01;
- выгрузить YouTube из recent apps;
- открыть YouTube заново и проверить, исчез ли белый экран или появились признаки прогрузки/видео.

Важно:
- правило временное и обратимое;
- если тест не поможет, удалить правило командой: iptables -D OUTPUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable.

## Обновление 2026-05-12 13:02 MSK — QUIC/UDP-443 firewall A/B откатан

Результат временного backend-only теста на UK-LON-01:
- после добавления правила OUTPUT UDP/443 REJECT пользователь не смог нормально запустить VPN;
- в UI показано Could not connect. Press the button to retry, затем snackbar Подождите 2s перед новой попыткой (diagnostic single tap);
- snackbar diagnostic single tap — это клиентский cooldown от частых повторных нажатий, не отдельная серверная ошибка;
- firewall A/B признан невалидным, потому что затронул старт/состояние VPN, а не только YouTube traffic после подключения.

Откат выполнен:
- команда на UK-LON-01: iptables -D OUTPUT -p udp --dport 443 -j REJECT --reject-with icmp-port-unreachable 2>/dev/null || true;
- проверка после отката: iptables -S OUTPUT -> только -P OUTPUT ACCEPT, правила UDP/443 больше нет.

Вывод:
- больше не использовать грубый node-level OUTPUT block для QUIC A/B;
- следующий backend-first тест должен быть мягче: либо selective Xray routing/config на клиентском JSON через backend, либо server-side профиль/порт без нарушения базового connect.

## Обновление 2026-05-12 13:08 MSK — logcat 13:03 и backend-only MTU 576 test

Сценарий:
- пользователь подключился к UK-LON-01 после отката firewall A/B;
- открыл YouTube; список видео не прогружается;
- logcat: OnePlus-MT2111-Android-14_2026-05-12_130319.logcat.

Logcat-факты:
- VPN подключается и доходит до COMMITTED;
- CONNECTIVITY_PROBE успешен: public_internet ok=true, api_health ok=true;
- маркер UDP включен: [UDP_GUARD] enabled=false forward_udp=true;
- client Xray видит YouTube flows:
  - youtubei: 6;
  - googlevideo / redirector.googlevideo: 6;
  - ytimg: 2;
  - accepted udp: 12;
  - accepted tcp: 24;
- локальных transport ошибок почти нет:
  - closed pipe: 0;
  - failed to read response header: 0;
  - i/o timeout: 0;
  - connection reset: 1;
- клиентский effective_outbounds: proxy/vless/45.140.167.123:4443/reality, direct/freedom/-:-/none.

Backend/node-факты:
- backend connect успешен на server_id=3;
- на UK-LON-01 во время/после YouTube снова массовые FIN-WAIT-1 на :4443 -> 94.180.243.40 с retrans/lost/backoff;
- это подтверждает, что телефонный Xray не падает локально, а полезный трафик деградирует на Reality TCP transport path.

Ограничение backend-only:
- текущий APK жестко выставляет mux.enabled=false для Reality в XrayConfig.toXrayNativeJsonConfig();
- поэтому включить mux через backend JSON нельзя без новой сборки: клиент пересобирает native JSON и снова выключает mux;
- гипотеза mux остается сильной, но она не backend-only для текущего APK.

Backend-only действие без новой сборки:
- на UK-LON-01 для текущего IP пользователя снижен route MTU:
  - было cache mtu 1000;
  - стало cache mtu 576;
  - команда: ip route replace 94.180.243.40 via 45.140.167.1 dev ens3 src 45.140.167.123 mtu 576;
  - ip tcp_metrics delete 94.180.243.40 выполнен.

Следующий тест:
- пользователь должен переподключить VPN к UK-LON-01, чтобы новые Reality TCP-сессии пошли с route MTU 576;
- открыть YouTube заново;
- если список/видео начнут грузиться, root cause — path/PMTU/MSS;
- если не поможет, backend-only путь почти исчерпан, следующий сильный тест — новая APK-сборка с Reality mux/concurrency experiment или альтернативным transport profile.

## Обновление 2026-05-12 13:24 MSK — backend-only исчерпан, собран Reality mux APK

Сценарий:
- пользователь переподключился к UK-LON-01 после backend-only route MTU 576;
- YouTube снова не прогрузился.

Live-срез после MTU 576:
- backend connect успешен на server_id=3;
- на UK-LON-01 по-прежнему массовые FIN-WAIT-1/retrans/lost на :4443 -> 94.180.243.40;
- pmtu реально стал 576, rcvmss/advmss около 524, но симптом не изменился;
- вывод: простое MSS/PMTU сжатие не решает проблему.

Откат/нормализация backend-only теста:
- route MTU для 94.180.243.40 на UK-LON-01 возвращен с 576 на 1000;
- команда: ip route replace 94.180.243.40 via 45.140.167.1 dev ens3 src 45.140.167.123 mtu 1000;
- ip tcp_metrics delete 94.180.243.40 выполнен.

Новая диагностическая сборка APK:
- файл изменен: mobile-app/lib/protocols/xray/models/xray_config.dart;
- в Xray native JSON для Reality включен mux:
  - mux.enabled=true;
  - mux.concurrency=8;
- цель: уменьшить число отдельных Reality TCP-сессий для YouTube/Google traffic и проверить гипотезу, что текущая деградация вызвана churn множества коротких TCP-соединений без multiplexing.

Сборка:
- команда: /opt/flutter/bin/flutter build apk --release --target-platform android-arm64;
- результат: build/app/outputs/flutter-apk/app-release.apk, размер 86.9 MB;
- sha256: 5d860b526770f67d3961f46989cc16562b94bc74f56a7a4201a268e5f195a8bf.

Публикация:
- файл размещен в активном nginx mount-source: /opt/grani/server-config/static-pages/downloads/grani-vpn-20260512-reality-mux.apk;
- важно: host /var/www/granivpn/downloads не виден nginx-контейнеру, активный bind-mount: /opt/grani/server-config/static-pages -> /var/www/granivpn/static-pages;
- проверка curl: https://api.granilink.com/downloads/grani-vpn-20260512-reality-mux.apk?cb=2 -> HTTP 200, content-type application/vnd.android.package-archive, content-length 86876251.

Ссылка для теста:
- https://api.granilink.com/downloads/grani-vpn-20260512-reality-mux.apk?cb=2

Следующий тест пользователя:
- установить APK reality-mux;
- подключиться к UK-LON-01;
- открыть YouTube;
- если YouTube начнет грузиться, root cause — слишком большой churn отдельных Reality TCP-сессий без mux;
- если не поможет или VPN не стартует, следующий шаг — logcat + node-срез, затем откат mux или тест другого transport profile.

## Обновление 2026-05-12 13:35 MSK — причина провала Reality mux APK

Сценарий:
- пользователь установил grani-vpn-20260512-reality-mux.apk;
- подключился к UK-LON-01;
- открыл YouTube;
- результат: белый экран.

Logcat: OnePlus-MT2111-Android-14_2026-05-12_132936.logcat.

Факты:
- mux реально включился: в logcat есть common/mux: dispatching request для TCP-доменов, включая:
  - youtubei.googleapis.com:443;
  - i.ytimg.com:443;
  - redirector.googlevideo.com:443;
- COMMITTED есть, CONNECTIVITY_PROBE успешен;
- локальных stage_error/fail_code нет;
- но появились новые ошибки, которых почти не было в предыдущем udp-open тесте:
  - ailed to process mux outbound traffic > XUDP rejected UDP/443 traffic;
  - 	ransport/internet/udp: failed to handle UDP input > io: read/write on closed pipe;
- счетчики по logcat:
  - accepted udp: 44;
  - accepted tcp: 38;
  - transport/internet/udp: 80;
  - closed pipe: 35;
  - connection reset: 11;
  - youtubei: 9;
  - googlevideo/redirector: 18;
  - ytimg: 3.

Интерпретация:
- текущая mux-сборка невалидна как финальный фикс, потому что TCP через mux пошел, но UDP/443 внутри mux/Xray отвергается без XUDP/packetEncoding поддержки;
- это объясняет текущий белый экран: YouTube открывается, но QUIC/UDP-потоки ломаются на клиентском Xray outbound после включения mux;
- при этом серверная проблема FIN-WAIT-1/retrans/lost на UK остается, но mux-тест теперь показал отдельный клиентский блокер — UDP over mux.

Следующие смелые варианты:
1. APK A: mux=true + локально blackhole UDP/443 для YouTube/всего UDP/443, чтобы принудительно перевести YouTube на TCP over mux и не отправлять UDP в mux вообще.
2. APK B: mux=true + VLESS packetEncoding/xudp для поддержки UDP over mux, если текущий серверный Xray inbound это принимает.
3. Более радикально: отдельный transport profile не на Reality TCP для YouTube-heavy traffic — например Hysteria2/TUIC/WireGuard-like UDP transport или sing-box profile, потому что YouTube плохо живет на текущем Reality TCP при массовых коротких потоках.

Текущий рабочий вывод:
- причина именно последней неудачи: mux включил TCP multiplexing, но сломал UDP/443 из-за отсутствия XUDP/packetEncoding; YouTube остается белым из-за QUIC/UDP failures.

## Корректировка 2026-05-12 13:55 MSK — фокус на починке Xray-настроек, не на миграции

Пользователь справедливо уточнил: 2 месяца назад в приложении работали все три Xray-протокола, поэтому текущая цель — не переход на альтернативные транспорты, а восстановление корректных внутренних настроек GRANI/Xray.

Решение по дальнейшей диагностике:
- альтернативные UDP-native transport profiles считать только стратегической идеей на потом, не текущим маршрутом починки;
- сейчас проверять и исправлять именно наши настройки Xray: VLESS/VMess/Trojan generation, Reality fields, UDP handling, mux/XUDP interaction, routing rules, server inbound/outbound compatibility;
- сборки делать только когда backend-only и config-only проверки исчерпаны;
- следующая рабочая гипотеза: регрессия находится в изменениях клиентской генерации native Xray JSON или серверной генерации профилей, а не в самом YouTube как приложении.

## Обновление 2026-05-12 14:35 MSK — найден рабочий APK и backend-mismatch на HU

Пользователь предоставил старый рабочий APK: app-release (4).apk, который точно подключался к VLESS и работал исправно.

Факты сравнения APK:
- старый APK sha256: FEED970FF7A9CEDB08EF52C71C4423048E9B31ED61D556239E42CF2263B43D2C;
- old libxray.so sha256 совпадает с текущей сборкой: 436BF6A84E2D4828081F2EC20AE25918FE99EF924DBE1050F4AC7323FC6FE8EA;
- old libgojni.so sha256 совпадает с текущей сборкой: 20E4FE83CD38786B889AF3475277B2FB71188B71A715BBD167EABDF7B4EB069B;
- old libapp.so отличается от текущего: значит Xray core тот же, регрессия в Dart/Kotlin логике, connect pipeline, routing или backend-selected protocol, а не в версии libxray;
- в старом APK нет строк /v2/vpn/xray/connect, xray_fetch_config, xray_expected_ports, CONFIG_MISMATCH, vless_ws_tls, vless_grpc_tls;
- старый APK использовал legacy endpoint /vpn/xray/create-client и простые xray_vless/xray_vmess/xray_reality.

Факты по HU-BUD-01:
- документ SWITCH_TO_XRAY.md описывает рабочий путь марта как XRay VLESS/VMESS на HU, VLESS порт 4443; Reality указан только как альтернатива;
- на HU сейчас xray-v2 active;
- порт 4443 слушает Xray;
- inbound 4443: protocol=vless, streamSettings.security=none, decryption=none, acceptProxyProtocol=false;
- порт 8443 слушает VMess;
- Reality inbound на 2053 на HU не слушает, но в БД было reality_enabled=true и supported_protocols включал xray_reality;
- это backend/server mismatch: приложение могло выбирать/восстанавливать Reality для HU, хотя рабочий серверный профиль на HU — plain VLESS/VMess.

Backend-only правка:
- для HU-BUD-01 (id=1) обновлена БД:
  - supported_protocols=[xray_vless, xray_vmess];
  - reality_enabled=false;
- цель: заставить текущий клиент после refresh/login выбирать рабочий VLESS/VMess путь на HU без новой APK-сборки.

Следующий тест:
- пользователь должен обновить список серверов/перезайти в приложение, выбрать HU-BUD-01 и протокол VLESS;
- подключиться и открыть YouTube;
- если заработает, root cause — не Xray core и не YouTube, а неверно рекламируемый/выбираемый Reality-профиль и новый connect pipeline по сравнению со старым VLESS APK;
- если не заработает, сравнивать текущий VLESS native JSON с legacy старого APK и временно отключать новый /v2/vpn/xray/connect pipeline в пользу /vpn/xray/create-client.

## Обновление 2026-05-12 14:55 MSK — главный подозреваемый: новый v2 connect pipeline

Пользователь предложил рассматривать новый connect/config pipeline как главную причину регрессии. Проверка подтвердила сильный backend-only механизм:
- старый рабочий APK использовал legacy endpoint /vpn/xray/create-client;
- текущий APK сначала ходит в /v2/vpn/xray/connect;
- в backend/api/xray_v2.py функция _resolve_v2_protocol() переводила xray_vless в xray_reality при traffic_profile=throughput;
- мобильный клиент для VLESS сам отправляет traffic_profile=throughput;
- следовательно, явный выбор VLESS в текущем v2 pipeline мог молча превращаться в Reality.

Почему это критично для HU:
- HU-BUD-01 реально имеет рабочий plain VLESS inbound на 4443;
- Reality на HU в runtime не слушает 2053, но ранее рекламировался через supported_protocols/reality_enabled;
- поэтому старый APK работал по VLESS, а новый pipeline мог уводить клиента в несовместимый Reality-путь.

Backend-only фикс применен:
- backend/api/xray_v2.py: _resolve_v2_protocol теперь сохраняет explicit xray_vless даже при traffic_profile=throughput/heavy/speedtest;
- API контейнер granivpn_api перезапущен;
- проверка внутри контейнера: _resolve_v2_protocol("xray_vless", "throughput") -> xray_vless.

Текущий следующий тест:
- в приложении обновить список серверов или перезайти;
- выбрать HU-BUD-01;
- выбрать/оставить VLESS;
- подключиться и открыть YouTube;
- ожидаем effective outbound: proxy/vless/45.12.132.94:4443/none, а не reality/2053;
- если YouTube оживет, root cause — v2 pipeline protocol remap + неверная реклама Reality на HU, а не Xray core.
## Обновление 2026-05-12 15:05 MSK — HU VLESS доходит, новый backend-only тест QUIC block inside Xray

После фикса v2 remap пользователь подключился к HU-BUD-01 и открыл YouTube, но он не работает.

Live-факты:
- backend выдал protocol=xray_vless для server_id=1, traffic_profile=throughput больше не превращается в Reality;
- device d2ef58de-97f0-4fc2-93a8-9225fe90e213 имеет vpn_client_id=vless_213_1, current_server_id=1;
- на HU в Xray config найден клиент 1_213@granivpn.com, uuid=9f084004-3934-492d-b2d5-2e2f64ff3ac7, inbound port=4443, protocol=vless, security=none;
- на HU есть множество соединений от 94.180.243.40 к 45.12.132.94:4443: ESTAB + FIN-WAIT-1;
- error.log HU пишет массово: app/proxyman/inbound: connection ends > read tcp 45.12.132.94:4443->94.180.243.40:<port>: i/o timeout;
- значит VLESS control/data TCP до сервера доходит, но нагрузочный поток внутри туннеля зависает/умирает.

Backend-only тест применен на HU:
- в /usr/local/etc/xray/config.json добавлен outbound blackhole tag=block-quic-udp443;
- первым routing rule добавлено: network=udp, port=443 -> block-quic-udp443;
- backup: /usr/local/etc/xray/config.json.grani-pre-quicblock-20260512.bak;
- systemctl restart xray-v2 выполнен, статус active.

Цель теста:
- заблокировать QUIC/UDP:443 внутри серверного Xray routing, а не iptables OUTPUT;
- не ломать старт VPN и TCP VLESS;
- проверить, начнет ли YouTube fallback на TCP/TLS через VLESS.

Следующий тест пользователя:
- переподключить HU-BUD-01 VLESS;
- открыть YouTube;
- если оживет, причина — UDP/QUIC churn внутри VLESS tunnel;
- если нет, следующий backend-only шаг: откатить quic block и проверять TCP path/concurrency/iptables churn guard/conntrack на HU.

## Обновление 2026-05-12 15:15 MSK — QUIC block не помог, найден строгий SYN churn guard на HU:4443

Пользователь протестировал HU после server-side Xray QUIC block: YouTube не работает.

Live-факты после теста:
- на HU:4443 сохраняется массовый FIN-WAIT-1 от 94.180.243.40;
- Xray error.log продолжает писать read tcp 45.12.132.94:4443->94.180.243.40:<port>: i/o timeout;
- значит блок UDP/443 внутри Xray не является root cause.

Откат:
- /usr/local/etc/xray/config.json восстановлен из /usr/local/etc/xray/config.json.grani-pre-quicblock-20260512.bak;
- xray-v2 перезапущен, статус active.

Новая сильная backend-only находка:
- на HU INPUT стоял дополнительный строгий SYN guard для VLESS 4443:
  - XRAYV2_4443_CHURN_GUARD: limit 15/sec burst 30 -> DROP;
  - затем базовый XRAYV2_GUARD: 80/sec burst 160;
- YouTube/Google через VLESS создает много коротких TCP-сессий, поэтому строгий 15/sec guard мог сам резать новые соединения клиента;
- это лучше объясняет FIN-WAIT-1/i/o timeout и отсутствие эффекта от QUIC block.

Backend-only тест применен:
- удален hook INPUT -> XRAYV2_4443_CHURN_GUARD для --syn --dport 4443;
- сама цепочка оставлена, но больше не вызывается;
- на 4443 остался только базовый XRAYV2_GUARD 80/sec burst 160.

Следующий тест пользователя:
- переподключить HU-BUD-01 VLESS;
- открыть YouTube;
- если оживет, root cause — наш server-side churn guard на 4443, который блокировал легитимный short-flow трафик YouTube.

## Обновление 2026-05-12 15:30 MSK — базовый guard не дропает, включен legacy fallback для VLESS

Пользователь протестировал HU после снятия строгого XRAYV2_4443_CHURN_GUARD: YouTube не прогружается.

Проверка firewall/conntrack:
- XRAYV2_4443_CHURN_GUARD hook снят;
- остался XRAYV2_GUARD 80/sec burst 160;
- счетчик DROP в XRAYV2_GUARD = 0;
- conntrack count около 110 при max 32768;
- значит текущий firewall/rate-limit не режет новые подключения.

Новая важная проверка:
- старый рабочий APK использовал legacy /vpn/xray/create-client;
- текущий APK предпочитает /v2/vpn/xray/connect и fallback на legacy только при HTTP 404;
- backend-only диагностический тест: для explicit xray_vless endpoint /v2/vpn/xray/connect теперь возвращает HTTP 404, чтобы текущий APK автоматически ушел в legacy /vpn/xray/create-client без новой сборки.

Изменение:
- backend/api/xray_v2.py: в connect_xray_v2 добавлен diagnostic legacy fallback для requested_protocol == xray_vless;
- granivpn_api перезапущен, статус healthy.

Следующий тест пользователя:
- переподключить HU-BUD-01 VLESS;
- открыть YouTube;
- если заработает, root cause — новый v2 connect/config pipeline;
- если не заработает, причина уже в текущем клиентском runtime JSON/apply path после получения legacy config, либо в нативном Android слое/tun2socks.

## Обновление 2026-05-12 17:25 MSK — legacy payload совпадает с active Xray, HU metadata выровнена под VLESS

Пользователь протестировал после diagnostic legacy fallback: результат прежний, YouTube не прогружается.

Проверка backend/control-plane:
- текущий device id=213 / device_id=77bacda1-3807-45cf-ba7a-95af6b963707 / vpn_client_id=vless_213_1 / current_server_id=1;
- legacy get_existing_connection_config для HU xray_vless возвращает VLESS TCP none на 45.12.132.94:4443;
- UUID в payload: 31343a66-e3b5-41e3-99df-cd901f8e052b;
- этот UUID совпадает с active /usr/local/etc/xray/config-v2.json в inbound 4443 для 1_213@granivpn.com;
- runtime_contract.has_mismatch=false;
- Redis xray_config cache перед проверкой отсутствовал/очищен, то есть простая stale-cache гипотеза не подтвердилась.

Проверка HU runtime:
- xray-v2 active;
- active config file: /usr/local/etc/xray/config-v2.json;
- inbound 4443: vless, tcp, security=none;
- outbound: freedom;
- routing блокирует только private IP, опасные порты и bittorrent;
- XRAYV2_GUARD DROP=0, conntrack не переполнен.

Backend-only изменение для чистоты следующего теста:
- server_id=1 HU-BUD-01 в БД приведен к legacy VLESS metadata:
  - xray_port=4443;
  - reality_enabled=false;
  - supported_protocols=[xray_vless, xray_vmess];
- Redis keys grani:cache:xray_config:server:1/3 и xray_config/apply_state для 1/3 очищены.

Важная клиентская находка из logcat 2026-05-12_132936:
- текущая сборка после получения json_config пересобирает нативный Xray config на Android;
- в effective outbound было видно packetEncoding=-;
- в mobile-app/lib/protocols/xray/models/xray_config.dart packetEncoding сейчас не добавляется для VLESS (комментарий: xudp amplifies UDP churn);
- backend-only добавление packetEncoding в json_config не поможет текущей сборке, потому что XrayConfig.fromJson не сохраняет это поле и toXrayNativeJsonConfig строит outbound заново.

Следующий тест без сборки:
1. Переподключить HU-BUD-01 VLESS после выравнивания metadata и очистки cache, открыть YouTube.
2. Если результат прежний, сделать A/B на HU-BUD-01 VMESS (порт 8443) без сборки: выбрать протокол VMESS в приложении и открыть YouTube.
3. Если VMESS оживет, главный подозреваемый — текущая Android-сборка VLESS native config/UDP packetEncoding/DNS path, а не server Xray и не backend endpoint.
4. Если VMESS тоже не оживет, переходить к сборке с диагностикой full effective config + возвратом VLESS packetEncoding=xudp как контролируемый A/B.

## Завершение сессии 2026-05-12 17:35 MSK

Текущая работа остановлена после backend-only выравнивания HU-BUD-01 под чистый legacy VLESS.

Зафиксированное состояние:
- HU-BUD-01 server_id=1 в БД:
  - xray_port=4443;
  - reality_enabled=false;
  - supported_protocols=[xray_vless, xray_vmess];
- Redis Xray config/apply cache для HU/UK очищен;
- backend/api/xray_v2.py все еще содержит диагностический fallback: explicit xray_vless на /api/v2/vpn/xray/connect возвращает 404, чтобы текущий APK уходил в legacy /api/vpn/xray/create-client;
- legacy payload для device id=213 совпадает с active Xray config-v2.json:
  - host=45.12.132.94;
  - port=4443;
  - tls=none;
  - uuid=31343a66-e3b5-41e3-99df-cd901f8e052b;
  - runtime_contract.has_mismatch=false;
- HU firewall/conntrack не показывает дропы или переполнение.

Нерешенная проблема:
- после legacy fallback пользователь сообщил “результат прежний”;
- backend payload и active server config совпадают, поэтому простая backend/config mismatch гипотеза на текущем шаге не подтвердилась.

Следующий рекомендованный тест без сборки:
1. Пользователь переподключается к HU-BUD-01 VLESS и открывает YouTube.
2. Если результат прежний, пользователь переключает протокол на VMESS на том же HU-BUD-01 и открывает YouTube.
3. Если VMESS работает, следующая сборка должна быть точечной: диагностировать/исправлять Android VLESS native config path, в первую очередь packetEncoding/UDP/DNS.
4. Если VMESS тоже не работает, продолжать backend/server-side аудит общего data-plane на HU, не переходя сразу к сборке.

Важно для продолжения:
- прежде чем делать новую APK-сборку, сначала исчерпать backend-only тест VMESS на HU;
- если диагностический fallback больше не нужен, его нужно убрать из backend/api/xray_v2.py отдельным осознанным шагом, чтобы вернуть обычный v2 pipeline.

## Обновление 2026-05-12 — VMESS A/B был заблокирован v2-валидацией

Пользователь протестировал после предыдущего состояния:
- VLESS подключается с трудом, по ощущениям есть внутренние конфликты/гонки;
- YouTube через VLESS не открылся;
- при попытке VMESS приложение получило HTTP 400 с текстом, что сервис поддерживает только VLESS и Reality.

Вывод:
- VMESS A/B тест не был реально выполнен на data-plane;
- запрос VMESS упал еще в /api/v2/vpn/xray/connect на _ensure_v2_protocol(), потому что v2-контур разрешал только xray_vless/xray_reality;
- следовательно, по этому тесту нельзя делать вывод, работает ли VMESS на HU:8443.

Backend-only диагностическая правка применена:
- /opt/grani/backend/api/xray_v2.py сохранен backup: /opt/grani/backend/api/xray_v2.py.bak-20260512-vmess-fallback;
- _ensure_v2_protocol теперь нормализует vmess -> xray_vmess и допускает xray_vmess;
- connect_xray_v2 теперь для requested_protocol in {xray_vless, xray_vmess} возвращает HTTP 404 diagnostic legacy fallback;
- цель: заставить текущий APK уйти в legacy /api/vpn/xray/create-client для VMESS так же, как сейчас для VLESS;
- python3 -m py_compile /opt/grani/backend/api/xray_v2.py прошел успешно;
- granivpn_api перезапущен, статус healthy.

Следующий тест пользователя:
1. Обновить/перезапустить приложение при необходимости.
2. Выбрать HU-BUD-01 и VMESS.
3. Подключиться и открыть YouTube.
4. Если VMESS теперь не дает 400, значит fallback сработал и тест наконец валиден.
5. Если VMESS работает, фокус сужается до VLESS native config path в текущей Android-сборке.
6. Если VMESS тоже подключается, но YouTube не работает, копать общий Android runtime/tun2socks/DNS/data-plane или HU server-side уже вне VLESS-specific гипотезы.

Важно:
- это временная диагностическая правка, не финальная архитектура v2;
- после диагностики нужно либо вернуть нормальную поддержку VMESS в v2, либо явно держать legacy fallback для legacy Xray-протоколов, либо убрать временный 404 fallback.

## Обновление 2026-05-12 21:15 MSK — VMESS A/B валиден, проблема не protocol-specific

Пользователь повторил VMESS после backend fallback:
- HTTP 400 ушел;
- VMESS подключился со второго раза;
- YouTube не прогрузился, пользователь находился в приложении YouTube во время диагностики.

Backend/API факты:
- /api/v2/vpn/xray/connect для xray_vmess вернул diagnostic 404;
- текущий APK ушел в legacy /api/vpn/xray/create-client;
- create-client вернул 200;
- apply-state по server_id=1 стал is_applied=True примерно за 5-6 секунд;
- значит VMESS тест действительно дошел до legacy data-plane, а не упал на v2 validation.

Mobile/client-log факты по device 82fa8c1c-779c-4028-995b-97acb08e40d8:
- device id=213, vpn_client_id=vmess_213_1, vpn_protocol=vmess, current_server_id=1;
- effective_outbounds: proxy/vmess/45.12.132.94:8443/none, direct/freedom/-:-/none;
- первый VMESS connect в 18:03 UTC падал по TimeoutException stage=apply_protocol;
- следующий connect в 18:04 UTC дошел до connected_local/traffic_first_seen;
- затем зафиксирован connected_degraded_retry: public_ok=false, api_ok=false, traffic_seen=true, reason=commit_window_expired_public_probe_failed_proxy_tunneling_seen.

HU/Xray runtime факты:
- xray-v2 active;
- active config file: /usr/local/etc/xray/config-v2.json;
- listeners: 4443 VLESS, 8443 VMESS, 2053 Reality;
- для 1_213@granivpn.com в config-v2.json есть:
  - VLESS 4443 id=31343a66-e3b5-41e3-99df-cd901f8e052b;
  - Reality 2053 id=2395810e-8bfa-4831-ab3f-399d5d4a8e1f;
  - VMESS 8443 id=bf1f8a57-8c32-45b5-8e7d-f746802a648f, alterId=0, security=none;
- backend legacy payload для VMESS отдает тот же id=bf1f8a57-8c32-45b5-8e7d-f746802a648f, port=8443, scy=none, net=tcp, tls=none;
- backend/server UUID mismatch по VMESS исключен.

Ключевой live-сигнал с HU:
- во время YouTube на VMESS сервер видит массовые TCP-подключения от client IP 94.180.132.76 к 45.12.132.94:8443;
- Xray пишет повторяющиеся ошибки:
  - proxy/vmess/inbound: invalid request from 94.180.132.76:<port>
  - proxy/vmess/encoding: failed to read request header
  - read tcp 45.12.132.94:8443->94.180.132.76:<port>: i/o timeout
- это означает: TCP до VMESS inbound доходит, но корректный VMESS request header/handshake не приходит или не доходит стабильно.

Вывод по текущей развилке:
- проблема не только VLESS-specific: VMESS тоже не тянет YouTube;
- backend payload и server config для VMESS совпадают;
- основной фокус смещается в текущий Android runtime path: TUN/tun2socks/SOCKS -> local Xray -> outbound TCP;
- симптомы похожи на то, что Xray outbound открывает TCP-соединения к серверу, но данные/VMESS handshake зависают до отправки или теряются в runtime bridge.

Дополнительная находка по проверкам connectivity:
- текущий public probe использует http://1.1.1.1/ первым кандидатом;
- native Xray JSON добавляет routing rule для 1.1.1.1/1.0.0.1/9.9.9.9/8.8.8.8 -> direct как DNS IP;
- поэтому public_ok по 1.1.1.1 может быть false-positive и не доказывает, что proxy dataplane жив;
- это может объяснять, почему UI/пайплайн считает соединение частично успешным, хотя YouTube через proxy не работает.

Следующий инженерный шаг:
1. Не тратить больше время на backend-only protocol mismatch для HU: VLESS и VMESS payload совпадают с server config.
2. Делать диагностическую APK-сборку, которая:
   - логирует полный effective native Xray JSON безопасно/редактированно (protocol/address/port/security/network/users fields/routing rules/probe target);
   - убирает 1.1.1.1 как primary public probe или помечает direct-probe отдельно от proxy-probe;
   - добавляет proxy-only probe на домен, который точно не попадает в direct DNS rule;
   - логирует локальные SOCKS/tun2socks ошибки и Xray outbound errors вокруг YouTube;
   - проверяет, не гонит ли current routing/protect/dialer path подключения к VPN-server в странный half-open режим.
3. Отдельно проверить старый рабочий APK против этой же HU-ноды, если возможно, чтобы отделить регрессию Android runtime от серверной среды.

## Обновление 2026-05-12 — Diagnostic APK App Conflict A

По уточнению пользователя фокус смещен с протоколов на внутренние конфликты приложения: все Xray-протоколы ведут себя плохо, поэтому нужно поочередно отключать общие app-модули вокруг connect/runtime.

Собрана первая диагностическая сборка App Conflict A без изменения Xray-протокольных параметров:
- APK на сервере: /opt/grani/granivpn-app-conflict-a-release.apk
- Локальная копия в Codex workspace: granivpn-app-conflict-a-release.apk
- sha256: 0d74f4731db763a438e56d6da0b7e915ebd3dfe539df5d3519da2a8ed54e9ac1

Что отключено в App Conflict A:
1. Native NetworkCallback / network-change evaluation в GraniVpnService.
2. Post-connect connectivity probe loop, включая degraded retries.
3. bindUnderlyingNetworkForControlPlane / unbindUnderlyingNetworkForControlPlane — теперь log-only/disabled.
4. applyVpnRoutingHotSwap и DNS policy hot-swap — disabled/log-only.
5. tun2socks closed-pipe soft reinit — disabled/log-only.
6. tun2socks health watcher actions — disabled.

Что НЕ менялось:
- VLESS/VMESS/Reality backend payload generation;
- Xray server config;
- native Xray outbound protocol fields;
- split tunnel уже был force-disabled ранее;
- XrayRoutingHelper уже был в DIAG_MINIMAL_ROUTING_MODE=true ранее.

Цель теста:
- проверить, мешает ли соединению app-level автоматика вокруг туннеля: network callback, probes, hotswap, soft reinit, health watcher;
- если YouTube оживет или сервер перестанет видеть empty/invalid VMESS/VLESS handshakes, root cause в одном из отключенных app-модулей;
- если поведение не изменится, следующий слой отключения — retry/cleanup timing или сам tun2socks bridge.

Рекомендуемый тест:
1. Установить App Conflict A поверх текущей сборки.
2. Запустить приложение свежо после установки.
3. Выбрать HU-BUD-01 и один протокол, лучше VMESS для чистого сравнения с последним live-тестом.
4. Одно подключение, без повторных быстрых тапов.
5. Открыть YouTube на 2-3 минуты.
6. Зафиксировать: подключился ли с первого раза, появился ли интернет/YouTube, остались ли на HU ошибки failed to read request header.

Откат файлов на сервере, если нужно:
- /opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt.bak-20260512-app-conflict-a
- /opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnPlugin.kt.bak-20260512-app-conflict-a
- /opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/XrayNativeWrapperTun2Socks.kt.bak-20260512-app-conflict-a

## Обновление 2026-05-12 22:15 MSK — App Conflict A не устранил проблему, фокус на TUN/tun2socks/local SOCKS

Пользователь установил диагностическую сборку App Conflict A:
- сначала случайно подключился к UK Reality;
- затем подключился к HU VMESS;
- в приложении YouTube по-прежнему ничего не прогрузилось.

Backend/API факты по новому device_id fe42e1c4-2557-44a5-89dc-01ea50f15941:
- 19:03 UTC: UK Reality через /api/v2/vpn/xray/connect вернул 200;
- 19:04, 19:05, 19:09 UTC: HU VMESS пошел через diagnostic 404 на /api/v2/vpn/xray/connect и legacy /api/vpn/xray/create-client;
- device id=213 теперь vpn_client_id=vmess_213_1, current_server_id=1, vpn_protocol=vmess;
- после теста is_vpn_enabled=false, то есть пользователь/приложение уже отключили VPN.

Client-log факт:
- после 19:00 UTC в client_logs для device id=213 новых runtime-событий нет, хотя backend connect-запросы есть;
- значит App Conflict A не дает достаточной клиентской телеметрии после новой установки/подключения, в следующую сборку нужен принудительный flush диагностик вокруг proxy-only probe и YouTube window.

HU/Xray live-факт:
- Xray на HU активен, слушает 4443 VLESS, 8443 VMESS, 2053 Reality;
- во время теста на 8443 снова идет поток ошибок от client IP 94.180.132.76:
  - proxy/vmess/inbound: invalid request from 94.180.132.76:<port>;
  - proxy/vmess/encoding: failed to read request header;
  - read tcp 45.12.132.94:8443->94.180.132.76:<port>: i/o timeout.

Вывод после App Conflict A:
- отключение NetworkCallback, post-connect probes/degraded retries, bindUnderlyingNetworkForControlPlane, routing/DNS hot-swap, tun2socks soft reinit и health watcher НЕ исправило YouTube;
- значит эти app-level модули больше не primary-root-cause;
- текущий главный подозреваемый — общий runtime dataplane ниже уровнем: TUN -> tun2socks -> локальный Xray SOCKS inbound -> Xray outbound TCP.

Следующий рекомендуемый диагностический шаг:
1. Собрать App Conflict B не как очередное отключение протоколов, а как изоляцию dataplane:
   - после старта Xray выполнить proxy-only HTTP(S) probe через 127.0.0.1:10808 без TUN/tun2socks;
   - цель probe: домен, который не попадает в direct DNS rules, например https://www.gstatic.com/generate_204 или https://www.youtube.com/generate_204;
   - залогировать результат и принудительно отправить client_logs.
2. Если proxy-only probe успешен и HU видит валидный VMESS/VLESS handshake, значит Xray config/outbound живы, а ломается TUN/tun2socks bridge.
3. Если proxy-only probe тоже дает на HU failed to read request header/i/o timeout, значит проблема внутри local Xray/protect/dialer/outbound path, а не в TUN/tun2socks.
4. Только после этого имеет смысл точечно отключать/заменять tun2socks или менять параметры локального Xray.

## Решение 2026-05-12 22:25 MSK — выполняем App Conflict B

Пользователь подтвердил: добавить в контекст и выполнять следующий диагностический шаг.

Принятый шаг:
- собрать App Conflict B с proxy-only диагностикой через локальный Xray SOCKS 127.0.0.1:10808;
- probe должен запускаться после старта Xray и не зависеть от трафика YouTube;
- цель — понять, ломается ли сам local Xray outbound или мост TUN/tun2socks.

Критерии результата:
1. Proxy-only probe успешен и на HU появляется валидный VMESS/VLESS handshake — проблема в TUN/tun2socks bridge.
2. Proxy-only probe также падает, а HU продолжает видеть failed to read request header/i/o timeout — проблема внутри local Xray/protect/dialer/outbound path.

Что добавить в сборку:
- лог события старта App Conflict B;
- proxy-only HTTP(S) probe через 127.0.0.1:10808 на внешний домен вне direct DNS rules;
- принудительный flush client_logs после результата probe;
- не менять серверные Xray payload/protocol params.

## Обновление 2026-05-12 23:40 MSK — App Conflict B собран

App Conflict B реализован и собран.

Артефакты:
- APK на сервере: /opt/grani/granivpn-app-conflict-b-release.apk
- Локальная копия в Codex workspace: granivpn-app-conflict-b-release.apk
- sha256: 9dadeebb4f6b9ca177cc922452221b2d9917e53b48486a0e7dd804d512f0d1a2

Изменения в mobile-app:
- /opt/grani/mobile-app/lib/services/vpn_service.dart
  - добавлен _runAppConflictBProxyOnlyProbe();
  - после connected_local запускается неблокирующий proxy-only probe через NativeVpnService.apiRequestViaLocalSocks();
  - цели probe: https://www.gstatic.com/generate_204, затем https://www.youtube.com/generate_204;
  - transport marker: local_xray_socks_127.0.0.1_10808;
  - события: app_conflict_b_proxy_probe_start/result/error;
  - после result/error выполняется flushDiagnosticsOnConnectFail(), чтобы не потерять логи.
- /opt/grani/mobile-app/lib/services/connection_logger.dart
  - app_conflict_b_proxy_probe_* добавлены в critical datapath flush entries.

Что не менялось:
- серверные Xray payload/protocol params;
- backend legacy fallback;
- Xray server config;
- TUN/tun2socks напрямую не отключались в этой сборке.

Проверка сборки:
- flutter analyze для vpn_service.dart и connection_logger.dart не дал новых compile errors; остались только старые lint/warning;
- flutter build apk --release --target-platform android-arm64 завершился успешно.

Как тестировать:
1. Установить granivpn-app-conflict-b-release.apk.
2. Открыть приложение свежо после установки.
3. Выбрать HU-BUD-01 и VMESS.
4. Подключиться один раз и подождать 40-60 секунд, даже до открытия YouTube: probe должен выполниться сам.
5. Затем открыть YouTube на 2-3 минуты.
6. После теста смотреть client_logs по событиям app_conflict_b_proxy_probe_* и HU Xray logs на 8443.

Интерпретация:
- Если app_conflict_b_proxy_probe_result ok=true/status 204 или другой HTTP status, а YouTube все равно не грузится — local Xray SOCKS/outbound работает, главный подозреваемый TUN/tun2socks bridge.
- Если app_conflict_b_proxy_probe_error и HU видит failed to read request header/i/o timeout — проблема глубже, в local Xray/protect/dialer/outbound path.

## Решение 2026-05-13 — стоп бесконечным сборкам, работаем без новой APK

Пользователь справедливо остановил направление: сначала нужно пытаться решить проблему без новых сборок и только в крайнем случае собирать APK.

Что сделано после замечания:
- начатая сборка App Conflict C остановлена;
- незавершенные C-правки в mobile-app откатаны обратно к состоянию App Conflict B;
- новых APK после App Conflict B не выпускать без явного согласования.

Текущий фокус без сборки:
1. Анализировать уже установленную App Conflict B.
2. Сверить backend connect-запросы, client_logs, device state и HU Xray access/error logs.
3. Отдельно разобрать рассинхрон: Android шторка показывает VPN connected, UI приложения крутится/не считает connect завершенным.
4. Использовать backend/server-only изменения только если они обратимы и явно помогают диагностике.

Наблюдение по App Conflict B тесту 2026-05-13:
- пользователь сообщил: результат прежний; в интерфейсе кнопка крутится, в Android-шторке VPN подключен, YouTube не открылся;
- backend видел новые HU VMESS попытки device_id=2e31bc61-0df0-484e-a967-23525ee4cad7 через diagnostic legacy fallback;
- client_logs после 2026-05-13 00:00 UTC не появились, app_conflict_b_proxy_probe_* отсутствуют;
- HU Xray в это же окно снова видел VMESS TCP на 8443 от 94.180.132.76 с failed to read request header/i/o timeout.

Вывод без новой сборки:
- App Conflict B probe был поставлен слишком поздно для этого сценария: он запускается после connected_local, а UI до connected_local не дошел;
- системный Android VPN/TUN при этом уже поднят и генерирует outbound-попытки к HU;
- проблема теперь формулируется как state mismatch + dataplane half-open: Android VPN active, app UI pending, server sees TCP without VMESS header.

## Обновление 2026-05-13 — без сборки: подтвержден stale/local VPN state conflict

Разбор App Conflict B без новой APK.

Факты из nginx/backend timeline:
- 04:24:23-04:24:39 UTC приложение после установки/логина ходило в API с source IP 45.12.132.94 (HU-BUD-01), а не с пользовательского 94.180.132.76;
- это означает, что на телефоне уже был активен локальный Android VPN/туннель через HU еще до новой попытки connect;
- 04:24:56 UTC /api/v2/vpn/xray/connect вернул diagnostic 404;
- 04:25:03 UTC legacy /api/vpn/xray/create-client вернул 200, rt=6.840s;
- 04:25:04 и 04:25:13 UTC apply-state по revision sha256:ba9c... вернул 200;
- 04:25:19 UTC второй create-client уже быстрый 200;
- 04:25:54 UTC приложение запросило /api/vpn/status и /api/vpn/devices;
- 04:25:55 UTC приложение отправило /api/vpn/disconnect;
- 04:25:58 UTC снова connect/create-client;
- 04:26:37 UTC снова /api/vpn/status + /api/vpn/devices + /api/vpn/disconnect.

Факты из HU Xray:
- 06:27-06:28 CEST (04:27-04:28 UTC), то есть уже после backend-disconnect, HU продолжал видеть TCP-подключения от 94.180.132.76 на 8443;
- Xray снова писал failed to read request header / i/o timeout.

Факты из DB:
- device id=213 / device_id=2e31bc61-0df0-484e-a967-23525ee4cad7 сейчас is_vpn_enabled=false, is_active=false, current_server_id=1, vpn_protocol=vmess, vpn_client_id=vmess_213_1;
- connection_logs за 2026-05-13 содержат только disconnect records 04:25:55 и 04:26:37; connect records по legacy VMESS не создавались как нормальная active session;
- client_logs после 2026-05-13 00:00 UTC отсутствуют, /api/vpn/logs/send в nginx в этот период не видно.

Кодовая причина рассинхрона без новой сборки:
- в mobile _syncConnectionState() при /vpn/status connected=true и локальном Dart _isConnected=false вызывает _forceDisconnectOnServer();
- _forceDisconnectOnServer() меняет только backend state, не останавливает локальный Android VPN/TUN;
- backend disconnect_device() для Xray действительно только сбрасывает состояние в БД и не удаляет Xray-клиента;
- поэтому получается split-brain: backend/UI думают disconnected/pending, а Android VpnService/TUN продолжает жить и гонять half-open VMESS TCP на HU.

Практический вывод:
- перед следующими тестами нужно обязательно очистить локальный Android VPN state, иначе все новые connect-тесты стартуют поверх stale туннеля;
- backend-only disconnect уже недостаточен, потому что он не выключает локальный VpnService;
- без новой APK следующий тест должен начинаться с ручного локального стопа: Android VPN tile/settings disconnect или перезагрузка телефона/force stop приложения, затем убедиться, что шторка не показывает VPN до запуска GRANI.

Следующий no-build тест:
1. На телефоне полностью выключить GRANI VPN локально: системная шторка/Settings VPN disconnect; если не исчезает ключ — force stop GRANI или reboot телефона.
2. До открытия GRANI убедиться, что в шторке нет VPN.
3. Открыть установленную App Conflict B.
4. Выбрать HU VMESS и нажать connect один раз.
5. Не открывать YouTube первые 60 секунд; сначала проверить, появятся ли /api/vpn/logs/send и connected_local/app_conflict_b logs.
6. Только после этого открыть YouTube.


## Обновление 2026-05-13 08:25 MSK — после очистки приложения Android VPN все равно остался активен

Пользователь сообщил:
- приложение предварительно очищено;
- после авторизации подключиться не удалось;
- при этом Android-шторка снова показывает активное VPN-подключение.

Live-факты backend/nginx:
- сразу после авторизации запросы `/api/auth/google/callback`, `/api/auth/me`, `/api/vpn/devices`, `/api/vpn/status` пришли с source IP `45.12.132.94` (HU-BUD-01), а не с обычного пользовательского IP;
- значит к моменту авторизации телефон уже ходил в API через старый локальный VPN-туннель;
- 05:18:14 UTC `/api/v2/vpn/xray/connect` вернул diagnostic 404;
- 05:18:22 UTC legacy `/api/vpn/xray/create-client` вернул 200 за ~7 секунд;
- 05:19:02 UTC повторный `/api/v2/vpn/xray/connect` снова 404;
- 05:19:03 UTC legacy `/api/vpn/xray/create-client` вернул быстрый 200;
- `/api/vpn/logs/send` за это окно не пришел.

Live-факты DB:
- device id=213 получил новый после очистки app device_id `a64d5353-f2f9-4ae5-bda2-af03be402b64`;
- до ручного backend reset был `is_active=true`, `is_vpn_enabled=true`, `current_server_id=1`, `vpn_protocol=vless`;
- выполнен backend-only reset для user_id=1/device id=213:
  - `is_active=false`;
  - `is_vpn_enabled=false`;
  - `current_server_id=null`;
  - `vpn_client_id=vless_213_1` сохранен.

Live-факты HU Xray:
- в момент проверки HU видит множество TCP-соединений от `94.180.243.40` к `45.12.132.94:4443`;
- состояние в `ss`: массово `FIN-WAIT-1`;
- `/var/log/xray/error.log` продолжает писать `read tcp 45.12.132.94:4443->94.180.243.40:<port>: i/o timeout`;
- это именно VLESS 4443, а не новый VMESS 8443 тест.

Вывод:
- очистка данных приложения не убивает уже поднятый Android `VpnService`/TUN;
- локальный VPN-интерфейс может переживать app data clear и продолжать гонять трафик через старый VLESS;
- backend reset помогает убрать ложный connected state в API/БД, но сам VPN-ключ в шторке он выключить не может;
- текущий блокер перед любыми следующими тестами — принудительно остановить локальный Android VPN на устройстве, иначе тесты снова идут через старый туннель.

Следующее обязательное действие на телефоне:
1. В Android Settings -> VPN найти GRANI и нажать Disconnect/Forget/удалить профиль, если доступно.
2. Проверить, что выключены Always-on VPN и Block connections without VPN для GRANI.
3. Сделать Force stop приложения GRANI.
4. Если VPN-ключ не исчезает из шторки — перезагрузить телефон.
5. До запуска GRANI убедиться, что в шторке нет VPN-ключа и API больше не идет с IP `45.12.132.94`.

Только после этого повторять no-build тест:
- открыть GRANI;
- выбрать HU VMESS;
- нажать connect один раз;
- первые 60 секунд не открывать YouTube;
- проверить появление `/api/vpn/logs/send` и `app_conflict_b_proxy_probe_*`.

## Обновление 2026-05-13 08:35 MSK — VMESS тоже поднимает Android VPN, но не отправляет protocol header

Пользователь сообщил после повторной попытки:
- подключиться не удалось;
- UI показывает ошибку “не удалось применить конфигурацию Xray”;
- Android-шторка при этом показывает активный VPN;
- YouTube не открывается.

Live-факты nginx/backend:
- после очередной очистки/авторизации появился новый device_id `311228ad-5f27-4a4f-9324-fee0724bad21`;
- 05:26:15 UTC `/api/v2/vpn/xray/connect` вернул diagnostic 404;
- 05:26:38 UTC тот же request_id `25da6d39-15ff-4e8c-9a63-c8ea8f3aa718` пришел дважды:
  - с `45.12.132.94` (через HU VPN);
  - с `94.180.243.40` (прямой пользовательский IP);
- это показывает гонку/переключение маршрутов в момент старта Android VPN;
- 05:26:39 UTC legacy `/api/vpn/xray/create-client` вернул 200;
- 05:27:20 UTC `/api/vpn/status` и `/api/vpn/devices`;
- 05:27:21 UTC приложение отправило `/api/vpn/disconnect`;
- `/api/vpn/logs/send` за это окно снова отсутствует.

Live-факты DB:
- device id=213 сначала был `is_active=false`, `is_vpn_enabled=false`, `current_server_id=1`, `vpn_protocol=vmess`, `vpn_client_id=vmess_213_1`;
- выполнен ручной backend reset:
  - `is_active=false`;
  - `is_vpn_enabled=false`;
  - `current_server_id=null`;
  - `vpn_protocol=null`;
  - `vpn_client_id=null`.

Live-факты HU Xray:
- теперь массовые соединения идут на `45.12.132.94:8443`, то есть VMESS;
- `ss` показывает множество `FIN-WAIT-1` от `94.180.243.40` к `8443`;
- `/var/log/xray/error.log` пишет:
  - `proxy/vmess/inbound: invalid request`;
  - `proxy/vmess/encoding: failed to read request header`;
  - `read tcp 45.12.132.94:8443->94.180.243.40:<port>: i/o timeout`;
- это означает: TCP до VMESS inbound доходит, но корректный VMESS header от клиента не приходит.

Вывод:
- проблема воспроизводится не только на VLESS 4443, но и на VMESS 8443;
- значит root cause уже не похож на отдельную VLESS/Reality/server payload настройку;
- Android VpnService успевает поднять системный VPN-интерфейс, но local Xray/native apply не доходит до COMMITTED/dataplane verified;
- из-за отсутствия `/api/vpn/logs/send` сервер не получает внутреннюю ошибку native слоя, поэтому для следующего точного шага нужен logcat с телефона за этот запуск.

Сильная текущая гипотеза:
- локальный Android слой поднимает TUN/VpnService до того, как libXray реально готов;
- затем libXray/native wrapper не стартует корректно или останавливается до отправки VMESS/VLESS header;
- приложение видит “не удалось применить конфигурацию Xray”, а Android продолжает показывать VPN-ключ, потому что TUN уже был поднят.

Следующий обязательный артефакт:
- logcat именно с запуска, где появилось “не удалось применить конфигурацию Xray”;
- фильтровать по `VpnPlugin`, `GraniVpnService`, `XrayNativeWrapper`, `XrayTun2Socks`, `libXray`, `VPN_START_FAILED`, `serviceState`, `CONNECTIVITY_PROBE`.

До получения logcat:
- не делать новую сборку;
- не продолжать YouTube-тесты, потому что сервер уже доказал: проблема на local Android apply/dataplane stage, а не в YouTube;
- backend/server-side настройки больше не являются главным подозреваемым на текущем этапе.

## Обновление 2026-05-13 08:45 MSK — причина текущей ошибки: APK сама не переводит VPN в COMMITTED

Артефакт:
- logcat `OnePlus-MT2111-Android-14_2026-05-13_083536.logcat`;
- сессия подключения `1778650448400_8fcc`;
- сервер HU id=1, протокол `xray_vmess`.

Что видно в logcat:
- `/api/v2/vpn/xray/connect` на первом проходе зависает на receive timeout около 20 сек;
- приложение уходит на legacy fallback `/api/vpn/xray/create-client` и получает `json_config`;
- `runtime_contract.has_mismatch=false`, то есть config contract на стороне Dart не ломается;
- effective outbound: `proxy/vmess/45.12.132.94:8443/none`;
- Android `VpnService` создает TUN, добавляет `10.0.0.2/30`, route `0.0.0.0/0`, throw routes для `45.12.132.94/32` и `159.223.199.122/32`;
- libXray успешно читает config и пишет `Xray 25.12.8 started`;
- native wrapper возвращает `{"success":true}`;
- `tun2socks` стартует и входит в event loop;
- локальный Xray принимает SOCKS-запросы от `127.0.0.1`, делает detour `[proxy]` и dial TCP к `45.12.132.94:8443`;
- затем через 30 сек приложение падает по timeout: `VPN не вышел в COMMITTED за отведенное время` / `Не удалось применить Xray конфигурацию`.

Ключевая находка в коде текущей APK/ветки:
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt` содержит diagnostic flag:
  - `DIAG_APP_CONFLICT_A_DISABLE_NETWORK_CALLBACK = true`;
  - `DIAG_APP_CONFLICT_A_DISABLE_POST_CONNECT_PROBES = true`;
- в `startVpnConnection` при включенном флаге логируется `[APP_CONFLICT_A] post-connect connectivity probes disabled`;
- единственный найденный путь к `setServiceState(ServiceState.COMMITTED)` находится внутри `runPostConnectConnectivityProbes()`;
- из-за отключенных post-connect probes текущая APK фактически отключает механизм, который должен перевести сервис из `LOCAL_UP` в `COMMITTED`.

Вывод:
- текущая ошибка “не удалось применить Xray конфигурацию” не доказывает поломку VMESS/VLESS на сервере;
- в этом запуске Xray, TUN и tun2socks реально стартуют;
- Android-шторка показывает VPN потому, что системный TUN уже поднят;
- UI получает ошибку потому, что приложение ждет `COMMITTED`, но диагностический флаг отключил единственный commit path;
- это regression от диагностической сборки App Conflict A/B, а не финальный вывод по серверным настройкам.

Следующий шаг:
- backend-only тесты на этом месте уже не дадут чистого результата, потому что текущая APK сама блокирует commit;
- нужна минимальная APK-сборка без `DIAG_APP_CONFLICT_A_DISABLE_POST_CONNECT_PROBES=true`;
- предпочтительный фикс для следующей сборки:
  - вернуть post-connect probes, либо
  - добавить fallback `COMMITTED`, когда одновременно подтверждены: libXray success, tun2socks started, SOCKS traffic accepted by Xray;
- после установки этой APK повторить HU VMESS/VLESS тест и только потом снова судить о серверном dataplane.

## Обновление 2026-05-13 08:50 MSK — собрана APK с включенным commit path

Изменение в Android:
- файл: `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt`;
- изменен только diagnostic flag:
  - было: `DIAG_APP_CONFLICT_A_DISABLE_POST_CONNECT_PROBES = true`;
  - стало: `DIAG_APP_CONFLICT_A_DISABLE_POST_CONNECT_PROBES = false`;
- `DIAG_APP_CONFLICT_A_DISABLE_NETWORK_CALLBACK` оставлен `true`, чтобы следующий тест проверял только один фактор.

Сборка:
- команда: `bash build_release_apk.sh` на `/opt/grani`;
- результат: `mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
- копия: `/opt/grani/granivpn-release-arm64.apk`;
- размер: 83 MB / `86876251` bytes;
- SHA256: `756ecf48d8209fcca4e843c404cf5992483f62ee010595baad89ff10a32ddcae`.

Публикация:
- основной путь обновлен: `https://api.granilink.com/downloads/app-release.apk?v=20260513-commit-probes`;
- чистая версионная ссылка: `https://api.granilink.com/downloads/grani-vpn-20260513-commit-probes-v2.apk`;
- проверка `curl -I` по versioned URL вернула `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `content-length: 86876251`, `last-modified: Wed, 13 May 2026 05:50:24 GMT`.

Проверка содержимого APK:
- в dex найдены `CONNECTIVITY_PROBE` и `grani-connectivity-probe`;
- строка `[APP_CONFLICT_A] post-connect connectivity probes disabled` в APK больше не найдена.

Следующий тест:
1. Установить свежую APK по versioned URL.
2. Перед запуском убедиться, что старый VPN выключен в Android-шторке/Settings -> VPN; при сомнении перезагрузить телефон.
3. Очистить приложение, авторизоваться.
4. Подключиться к HU VMESS/VLESS.
5. Не открывать YouTube первые 60 секунд после нажатия connect.
6. В logcat ожидаемые новые признаки:
   - появление `[CONNECTIVITY_PROBE]`;
   - переход `serviceState=COMMITTED` или точная причина failed/degraded probe;
   - отсутствие прежнего timeout `VPN не вышел в COMMITTED`.

## Обновление 2026-05-13 09:13 MSK — logcat после сборки не содержит старта Android VPN

Артефакт:
- logcat `OnePlus-MT2111-Android-14_2026-05-13_091305.logcat`;
- окно лога: примерно `09:12:05`–`09:13:02 MSK`;
- device_id в клиентских логах: `189a8020-305a-4bc0-ad13-ff0e5e2e99a3`.

Что есть в logcat:
- каждые ~1 сек приложение пытается отправить 7 накопленных client logs;
- `bases_try_first=https://159.223.199.122/api`;
- `/vpn/logs/send` получает локальный/контрольный отказ: `ControlPlaneDeniedException: logging only after COMMIT (connected)`;
- периодически встречается `skip_reason=vpn_transitioning`.

Чего нет в logcat:
- `connect_stage`;
- `xray-timing`;
- `startVpn`;
- `runXray`;
- `tun2socks`;
- `VpnPlugin` / `GraniVpnService`;
- `CONNECTIVITY_PROBE`;
- `LOCAL_UP` / `COMMITTED`.

Параллельная проверка backend/nginx за `09:11:50`–`09:13:20 MSK`:
- последний релевантный запрос перед этим окном: `/api/vpn/xray/apply-state?...wait_for=applied&timeout_sec=15`;
- он завершился `is_applied=False`, `timed_out=True`, `server_id=1`;
- в nginx этот apply-state запрос шел с IP `45.12.132.94`;
- после этого в backend/nginx за 09:12-09:13 не видно нового успешного connect/start VPN события.

DB state на device id=213:
- `device_id=189a8020-305a-4bc0-ad13-ff0e5e2e99a3`;
- `is_active=true`;
- `is_vpn_enabled=true`;
- `current_server_id=1`;
- `vpn_protocol=vmess`;
- `vpn_client_id=vmess_213_1`;
- `last_connected=2026-05-12 19:03:41`, то есть не обновился на свежую попытку 2026-05-13.

Вывод:
- текущий logcat не показывает падение Android VPN или Xray, потому что до Android VPN start дело в этом окне не дошло;
- приложение находится в состоянии `vpn_transitioning`, но backend/server apply не подтвержден;
- logging pipeline сам блокирует отправку диагностических логов до `COMMIT`, поэтому самые полезные 7 логов не доходят на сервер;
- backend продолжает хранить активное VPN-состояние устройства, хотя реального COMMIT нет;
- это подтверждает главный архитектурный диагноз: connect/config/apply/state pipeline расходится с фактическим состоянием клиента и сервера.

Важно:
- новых правок кода в этом шаге не делалось;
- последняя APK-сборка не является направлением лечения, а только диагностически подсветила, что блокер выше Android dataplane.


## Обновление 2026-05-13 12:55 MSK — self-capture guard не исправил YouTube, применён HU route MTU 1200

Артефакт:
- logcat `OnePlus-MT2111-Android-14_2026-05-13_125131.logcat` после APK `grani-vpn-20260513-self-capture-guard.apk`.

Факты logcat:
- пользователь подключился со второго раза, YouTube не грузит;
- в окне лога нет фазы старта Android VPN (`COMMITTED`, `tun2socks`, `protectFd`, `own package excluded from VPN` отсутствуют), но есть активный Xray dataplane;
- YouTube/Googlevideo идут через HU VLESS:
  - `youtubei.googleapis.com`, `i.ytimg.com`, `redirector.googlevideo.com`;
  - `proxy/vless/outbound ... via 45.12.132.94:4443`;
  - UDP/TCP `:443` принимаются на `socks-in -> proxy`;
- клиентских `closed pipe` / `i/o timeout` в этом logcat нет.

Backend/server факты:
- `/api/v2/vpn/xray/connect` для HU VLESS корректно ушёл в diagnostic legacy fallback 404;
- `/api/vpn/xray/create-client` вернул 200;
- apply-state снова не подтвердился (`is_applied=False`), но client dataplane реально активен;
- на HU для client IP `94.180.243.40` после теста снова массовые `FIN-WAIT-1` на `:4443` с `unacked=1 retrans/lost=1`, `pmtu:1500`;
- `xray error.log` содержит плотную серию `read tcp 45.12.132.94:4443->94.180.243.40:*: i/o timeout`.

Вывод:
- self-capture guard не устранил симптом;
- основной текущий сигнал — не Xray auth/config mismatch и не Android COMMIT, а обратный TCP path HU -> client IP под YouTube/churn нагрузкой;
- проблема проявляется как зависшие outbound TCP-сессии сервера к клиенту с retrans/lost.

Backend-only действие применено на HU-BUD-01:
- для текущего client IP `94.180.243.40` выставлен route MTU 1200:
  - `ip route replace 94.180.243.40 via 45.12.132.1 dev ens3 src 45.12.132.94 mtu 1200`;
  - `ip tcp_metrics delete 94.180.243.40`;
  - `sysctl -w net.ipv4.tcp_mtu_probing=1`;
- проверка: `ip route get 94.180.243.40` -> `cache mtu 1200`.

Следующий тест:
1. Полностью переподключить VPN на HU VLESS, чтобы новые TCP-сессии открылись с route MTU 1200.
2. Открыть YouTube.
3. Если не поможет, следующий backend-only шаг — снизить route MTU до 1000 для того же IP и повторить без новой APK.

## Обновление 2026-05-13 — стратегическое решение: stop-fix legacy Grani VPN, пишем новый simple VPN контур

После серии тестов пользователь и Codex приняли решение остановить текущую линию маленьких диагностических фиксов старого Grani VPN-контура.

Причина:
- уже проверялись и не дали устойчивого результата порты, MTU/PMTU, UDP/QUIC блокировки, clean/minimal tunnel, HU/UK A/B, VLESS/VMESS/Reality варианты, legacy/v2 payload alignment, apply-state/COMMIT/session fixes, app conflict отключения, observability/logging правки и self-capture guard;
- текущий VPN-контур стал слишком связанным: frontend, backend sessions, apply-state, observability, dynamic server/protocol selection, native Android VPN, tun2socks/Xray wrapper и server runtime влияют друг на друга;
- продолжение формата  еще одна маленькая сборка/флаг признано непродуктивным.

Решение:
- НЕ удалять проект физически: старый Grani оставить как forensic/legacy archive;
- НЕ скрывать кнопки и старые состояния косметически;
- НЕ строить новый путь поверх старого pipeline;
- написать новый frontend + backend VPN path отдельно от legacy Grani VPN.

Целевой MVP нового контура:
- после авторизации пользователь видит один простой VPN экран;
- одна главная кнопка connect/disconnect;
- один выбранный сервер/protocol по умолчанию;
- backend только проверяет auth/subscription и отдает готовую Xray config;
- Android напрямую запускает native Xray/TUN по этой config;
- observability/logs только записывают факты, но не управляют подключением.

Новый backend API, отдельный от старого /api/vpn/* и /api/v2/vpn/*:
- GET /api/simple-vpn/config — вернуть готовый config для текущего пользователя/device;
- POST /api/simple-vpn/session/start — простая фиксация намерения/старта, без apply-state;
- POST /api/simple-vpn/session/stop — простая фиксация stop;
- GET /api/simple-vpn/session/status — последнее простое состояние, без degraded/public_ok/api_ok;
- POST /api/simple-vpn/logs — принять минимальные client logs, без COMMIT gate.

Что НЕ переносить в новый MVP:
- старый v2/legacy dual connect fallback как runtime architecture;
- apply-state как блокирующий этап;
- backend ACK/COMMIT как источник истины для Android VPN;
- degraded mode;
- public/API/speedtest probes как условие успеха connect;
- observatory gating;
- edge-agent / pending assignment loops;
- protocol auto-remap VLESS -> Reality;
- dynamic runtime inbound guessing/cache для первого MVP;
- split tunnel;
- routing/DNS hot-swap;
- NetworkCallback reconnect automation;
- health watcher / soft reinit;
- mux;
- QUIC/UDP guard feature flags;
- server-side churn guards как часть продукта;
- множественный выбор серверов/протоколов в первом релизе.

Что можно оставить/использовать:
- auth;
- subscription check;
- device id, если он не тянет старый session pipeline;
- текущие Xray native binaries/libxray/libgojni;
- server inventory/known static Xray credentials;
- download/build pipeline;
- simple log collector, но не как управляющий слой.

Правило реализации:
- новый путь должен быть отдельным ребром: Auth -> Simple VPN Config API -> Simple Android Runner -> Xray Server;
- legacy Grani VPN код не чинить по дороге, если он не является прямой зависимостью нового simple path;
- любые старые UI элементы, sessions, observatory states и diagnostics не скрывать косметически, а не использовать в новом flow вообще.

Первый acceptance test:
1. Пользователь авторизуется.
2. Видит новый simple VPN экран.
3. Нажимает одну кнопку.
4. VPN подключается.
5. YouTube реально грузит видео.
6. Client logs доходят независимо от COMMIT.
7. Server Xray logs не показывают массовые invalid header / i/o timeout сразу после старта.


## Обновление 2026-05-13 — реализован первый simple VPN core MVP

Сделано:
- добавлен новый backend router ackend/api/simple_vpn.py;
- подключен в ackend/main.py как /api/simple-vpn/*;
- backend API перезапущен, https://api.granilink.com/api/simple-vpn/config снаружи отвечает 401 без токена, то есть маршрут жив и требует auth;
- новый backend path не вызывает VPNOperationsService, legacy /api/vpn/*, v2 /api/v2/vpn/*, apply-state, COMMIT/ACK, edge-agent или observatory;
- добавлен новый mobile frontend/runtime path:
  - mobile-app/lib/simple_vpn/simple_vpn_api.dart;
  - mobile-app/lib/simple_vpn/simple_vpn_controller.dart;
  - mobile-app/lib/simple_vpn/simple_vpn_screen.dart;
- mobile-app/lib/screens/main_content_screen.dart переключен на SimpleVpnScreen, старый VpnShellBody больше не является главным экраном после auth;
- mobile-app/lib/core/vpn/control_plane_plane_resolver.dart относит /simple-vpn/logs к logging plane;
- simple controller делает только: fetch config -> start session intent -> NativeVpnService.connect -> simple log;
- логирование /simple-vpn/logs не является условием подключения и не зависит от COMMIT.

Проверки:
- python3 -m py_compile backend/api/simple_vpn.py backend/main.py — OK;
- /opt/flutter/bin/flutter analyze lib/simple_vpn lib/screens/main_content_screen.dart lib/core/vpn/control_plane_plane_resolver.dart --no-fatal-infos --no-fatal-warnings — OK;
- release APK собран: /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk.

Артефакт для установки:
- URL: https://api.granilink.com/downloads/grani-vpn-20260513-simple-vpn-core.apk;
- sha256: d544b619480f2e7bd8d111b58f61fa2bc467e0406ce46985137bc517eab2644e.

Важно для следующего теста:
- эта сборка не должна показывать старый VPN shell после авторизации;
- ожидаемый экран — простой статус + одна кнопка;
- если YouTube не работает и тут, следующий анализ должен идти по новому простому path, а не возвращаться к legacy apply-state/degraded/session pipeline.


## Обновление 2026-05-13 — simple VPN first test: backend 500 на session/start исправлен

Артефакт:
- logcat OnePlus-MT2111-Android-14_2026-05-13_135000.logcat;
- пользователь увидел Ошибка подключения в новой simple VPN сборке.

Backend факты:
- /api/simple-vpn/config с токеном успешно отдавал 200;
- /api/simple-vpn/session/start падал 500;
- ошибка: NameError: name 'default' is not defined в ackend/api/simple_vpn.py::_simple_key.

Причина:
- при создании файла строка _simple_key была повреждена кавычками: вместо строкового 'default' получился bare identifier default.

Исправление:
- _simple_key теперь:
  - alue = (device_id or 'default').strip() or 'default';
  - 
eturn f'{user_id}:{value}';
- python3 -m py_compile backend/api/simple_vpn.py — OK;
- granivpn_api перезапущен и healthy.

Smoke-test после hotfix:
- с тестовым access token user_id=1:
  - GET /api/simple-vpn/config -> 200;
  - POST /api/simple-vpn/session/start -> 200;
  - POST /api/simple-vpn/logs -> 200.

APK менять не нужно: ошибка была backend-side, установленную сборку grani-vpn-20260513-simple-vpn-core.apk можно тестировать повторно.


## Обновление 2026-05-13 — simple VPN подключился, YouTube не открылся: frontend/backend legacy исключены

Артефакт:
- logcat OnePlus-MT2111-Android-14_2026-05-13_135539.logcat;
- APK: grani-vpn-20260513-simple-vpn-core.apk;
- пользователь: VPN подключился, YouTube не открылся.

Backend simple-vpn факты:
- GET /api/simple-vpn/config -> 200;
- POST /api/simple-vpn/session/start -> 200;
- POST /api/simple-vpn/logs получил vent=native_start_ok, session_id=4d89f3b6-053f-4831-93dc-8798cf315291;
- значит новый simple frontend/backend path дошел до native VPN start успешно.

Logcat факты:
- есть активный Xray dataplane;
- YouTube/Google traffic попадает в локальный Xray SOCKS:
  - youtubei.googleapis.com:443;
  - 
edirector.googlevideo.com / googlevideo;
  - TCP и UDP :443;
  - proxy/vless/outbound ... via 45.12.132.94:4443;
- counts по logcat:
  - proxy/socks около 46;
  - proxy/vless/outbound около 45;
  - youtube около 1806;
  - googlevideo 9;
  - closed pipe 0;
  - client-side i/o timeout 0.

HU-BUD-01 server факты:
- xray-v2.service active;
- listeners активны: 4443 VLESS, 8443 VMESS, 2053 Reality;
- /var/log/xray/error.log снова показывает плотные:
  - pp/proxyman/inbound: connection ends > read tcp 45.12.132.94:4443->94.180.243.40:<port>: i/o timeout;
- это совпадает с прежним симптомом до rewrite.

Вывод:
- новый simple frontend/backend contour исключает старую Grani UI/session/apply-state/degraded/observatory машину как root cause текущего YouTube failure;
- проблема остается в data-plane после успешного native VPN start;
- текущая формулировка: Android локально отдает YouTube flows в Xray, Xray outbound открывает VLESS к HU:4443, но на сервере соединения заканчиваются inbound read timeout от client IP;
- дальнейшие действия не должны возвращаться к legacy frontend/backend правкам. Нужно исследовать низкий слой: server/client TCP path, Xray inbound/outbound framing under churn, Android native/tun2socks bridge или провайдерский/маршрутный return path.


## Обновление 2026-05-13 — Amnezia A/B: внешний клиент тоже подключается, YouTube не грузит

Пользователь импортировал HU VLESS config в Amnezia:
- profile: GRANI-HU-VLESS;
- XRay / 45.12.132.94;
- config содержит VLESS TCP none на 45.12.132.94:4443, uuid 31343a66-e3b5-41e3-99df-cd901f8e052b.

Результат:
- подключение в Amnezia произошло;
- YouTube не прогрузился.

Вывод:
- failure воспроизводится вне нашего APK и вне нашего native Android runtime/tun2socks wrapper;
- это резко снижает вероятность root cause в новом/старом mobile frontend, Dart controller, NativeVpnService, XrayNativeWrapper или backend session/apply-state;
- текущий главный подозреваемый: HU/server/provider/route/TCP path или конкретная серверная Xray/VLESS TCP none схема под YouTube traffic;
- следующий полезный A/B: тот же телефон + Amnezia + Xray на другом сервере пользователя. Если другой сервер грузит YouTube, HU/provider/data-plane виноват. Если другой сервер тоже не грузит, проблема шире: оператор/сеть клиента блокирует/ломает такой Xray/VLESS профиль или схема plain VLESS TCP none непригодна для этой сети.


## Обновление 2026-05-13 — рабочий внешний контроль: AmneziaWG работает, Xray/VLESS нет

Пользователь сообщил:
- в Amnezia сейчас работает обфусцированный AmneziaWG (pn://... key);
- на том же устройстве/среде VLESS/Xray-клиенты подключаются, но YouTube/Speedtest не грузятся;
- Xray Reality на пользовательском сервере подключить не удалось.

Вывод:
- проблема не выглядит как общий Android VPN/system-wide internet failure, потому что AmneziaWG работает;
- проблема не выглядит как конкретно HU-BUD-01 server-only failure, потому что сторонний VLESS-клиент тоже подключается без полезного трафика;
- текущая граница: класс Xray/VLESS profiles, которые тестировались (plain VLESS TCP none / похожие VLESS clients), непригоден или блокируется/ломается в целевой среде, тогда как AmneziaWG/обфусцированный WireGuard работает;
- продуктовый путь теперь должен ориентироваться на рабочий класс протокола (AmneziaWG/обфусцированный WG) либо на серьезную переработку Xray профиля, а не на UI/backend/mobile fixes.

Практическое следствие:
- не тратить время на Wi-Fi/mobile A/B как главный продуктовый путь;
- не возвращаться к legacy Grani frontend/backend/apply-state;
- следующий инженерный выбор: либо интегрировать AmneziaWG-compatible/obfuscated WireGuard в новый simple core, либо отдельно исследовать другой Xray profile, но plain VLESS TCP none уже считать неподходящим для MVP.


## 2026-05-13 - AmneziaWG + alternative protocols development start

User decision: develop directions 1 and 3:
1. Main product path: obfuscated WireGuard / AmneziaWG, because it is the only VPN class proven working on the same phone/network outside Grani.
3. Reserve path: alternative protocols, but gated by external-client proof before integrating runtime weight into Grani.

Implemented first vertical slice for direction 1:
- backend `/api/simple-vpn/config` now has `config_type` and `engine` fields.
- backend can switch to `SIMPLE_VPN_PROTOCOL=graniwg|amneziawg|awg` and return an AmneziaWG quick config from `SIMPLE_AWG_CONFIG`.
- backend `/api/simple-vpn/protocols` documents current protocol states: `graniwg` development, `xray_reality_utls` external R&D gate, `hysteria2`/`tuic`/`naive_proxy` reserve candidates.
- Flutter simple VPN path now branches by engine: `xray` still uses existing Xray native path; `amneziawg` calls new MethodChannel methods.
- Android app now includes embedded `third_party/amneziawg-android/tunnel` as `:amneziawg-tunnel` and has `SimpleAmneziaWgRunner` over `org.amnezia.awg.backend.GoBackend`.
- Android `VpnPlugin` now handles `connectAmneziaWg` and `disconnectAmneziaWg`.
- Packaging conflict with legacy `wireguard_flutter` transitive `com.wireguard.android:tunnel` fixed by excluding that transitive AAR from the app configuration; Android never manually registers that old plugin.

Validation:
- `python3 -m py_compile backend/api/simple_vpn.py` passed.
- `flutter analyze lib/simple_vpn lib/services/native_vpn_service.dart --no-fatal-infos --no-fatal-warnings` passed with only pre-existing info-level messages in `native_vpn_service.dart`.
- `cd mobile-app/android && ./gradlew :app:assembleDebug --no-daemon --stacktrace` passed.
- Debug artifact: `mobile-app/build/app/outputs/apk/debug/app-debug.apk`.

Important constraints / next steps:
- This is a compile-ready AmneziaWG app path, not yet a production provisioning path. It currently expects server-side `SIMPLE_AWG_CONFIG`; do not put user-provided Amnezia `vpn://...` secrets into docs or code.
- Next backend work is real per-device AWG provisioning: generate/store client keys/IP, add peer to selected AWG server, return per-device quick config, and keep it separate from legacy session/apply-state pipeline.
- Alternative protocols stay candidates until external proof on same Russian network conditions. Do not integrate sing-box/libbox into the mobile runtime until one candidate works in an external client.

Reality/uTLS R&D gate detail:
- This is deliberately not another Grani build first. Build one clean external Xray REALITY profile with uTLS fingerprint (`chrome`/`safari`), realistic SNI, public key, shortId, spiderX, and test it in an external client such as v2rayNG/NekoBox/Amnezia if supported.
- Acceptance: same phone/network loads YouTube video for >60s, Speedtest starts download, no repeated reconnects, server logs do not show the dense timeout pattern seen with plain VLESS.
- If Reality/uTLS fails externally, stop Xray branch. If it works externally, integrate as optional protocol behind a feature flag after AmneziaWG MVP, not as default.

## 2026-05-13 - AmneziaWG provisioning enabled and release APK built

Implemented next step after compile-ready AmneziaWG vertical slice:
- `simple-vpn` backend no longer requires only static `SIMPLE_AWG_CONFIG`.
- With `SIMPLE_VPN_PROTOCOL=graniwg` and `SIMPLE_AWG_PROVISION=true`, `/api/simple-vpn/config` now provisions a per-device AmneziaWG config:
  - creates/reuses a stable `Device` row by `device_id` (or deterministic `simple-awg-user-{user_id}` fallback);
  - generates WireGuard-compatible Curve25519 private/public keys locally inside API (no SSH key generation on node);
  - allocates next WireGuard IP through existing `WireGuardManager`;
  - adds peer to selected server through existing remote WireGuard manager;
  - returns AmneziaWG quick config with `config_type=amneziawg`, `engine=amneziawg`, `json_config.source=provisioned`.
- Idempotency: if the same device already has `ip_address`, `current_server_id`, and `vpn_protocol=graniwg`, repeated `/config` returns the same config revision/IP and does not allocate a new IP.
- Docker compose now sets API env:
  - `SIMPLE_VPN_SERVER_ID=1`
  - `SIMPLE_VPN_PROTOCOL=graniwg`
  - `SIMPLE_AWG_PROVISION=true`
- API container restarted and env verified.

Smoke validation:
- `/api/simple-vpn/protocols` returns default protocol `graniwg`.
- `/api/simple-vpn/config?device_id=simple-awg-smoke-user-1` returned 200 with `protocol=graniwg`, `engine=amneziawg`, `source=provisioned`, VPN IP `10.0.0.3`.
- Repeated call returned the same revision/IP, confirming idempotency.
- Smoke test peer/device was then removed from DB and remote WireGuard config to avoid leaving test pollution.

Mobile release:
- Removed legacy `wireguard_flutter` dependency from mobile app; old legacy GraniWG methods now throw/are disabled and no longer pull the old WireGuard Android runtime into release.
- Release APK built successfully with embedded AmneziaWG runtime.
- Published: `https://api.granilink.com/downloads/grani-vpn-20260513-amneziawg-mvp.apk`
- SHA256: `75cce61ec08573479c958fe76353f6fc39d305b8e41b9f539e3aa5740abb0895`

Operational note:
- `/opt/grani` filesystem is critically full: 58G/58G used, only ~81M free after moving APK. Future builds may fail until old build artifacts/APKs are cleaned.

## 2026-05-13 - Classic UI restored, Xray archived, AmneziaWG integrated into main flow

User decision after successful AmneziaWG MVP test:
- Restore the old/main Grani UI instead of the emergency `SimpleVpnScreen`.
- Treat Xray/VLESS as archived until better conditions/external proof.
- Integrate the proven AmneziaWG protocol into the old UI connect/disconnect flow.

Implemented:
- `MainContentScreen` now returns `VpnShellBody` again (old/main shell UI after auth), not `SimpleVpnScreen`.
- `VpnProtocol.graniwg` is now implemented on Android; Xray protocols are disabled by default behind compile flag `GRANI_ENABLE_ARCHIVED_XRAY`.
- `VpnService` default selected protocol changed to `graniwg`.
- `_findBestProtocol()` now prefers `graniwg` and falls back to `graniwg`, not Xray Reality.
- Legacy UI connect flow now fetches GraniWG config through the verified `/simple-vpn/config` provisioning path, not old `/vpn/connect`.
- Legacy UI applies GraniWG on Android via `NativeVpnService.connectAmneziaWg()` and disconnects via `NativeVpnService.disconnectAmneziaWg()`.
- Backend `/simple-vpn/protocols` marks Xray Reality/uTLS as `archived_external_rnd_only` / `archive_until_external_proof`.

Validation:
- Flutter analyze passed for touched files with non-fatal pre-existing warnings only.
- API env still active: `SIMPLE_VPN_SERVER_ID=1`, `SIMPLE_VPN_PROTOCOL=graniwg`, `SIMPLE_AWG_PROVISION=true`.
- API container healthy.
- Release APK built and published:
  - URL: `https://api.granilink.com/downloads/grani-vpn-20260513-classic-ui-amneziawg.apk`
  - SHA256: `68ebe3dc6c66a2369ce4ec30c08f2a421cf7a4eacb7481c7bac2177ef1d1d69d`

Test focus:
- Install this APK, login, confirm old UI is back.
- Press connect from the old main button.
- Expected protocol is GraniWG/AmneziaWG through `/simple-vpn/config`, not Xray.
- Verify YouTube and Speedtest as before.

## 2026-05-13 - Clean AmneziaWG active path, legacy VPN internals removed from runtime flow

Reason:
- The classic-UI AmneziaWG build connected, but after returning from background the UI button could be disabled while Android still showed the VPN icon, and retry could fail with state synchronization errors.
- Since the protocol itself is proven working by the AmneziaWG MVP, the old Grani `VpnService` session/apply/resume/server/protocol state machine is now treated as interference for the working VPN path.

Implemented:
- Active post-auth subscription screen now opens `CleanAmneziaHomeScreen`, not the old `HomeScreen` flow.
- `CleanAmneziaHomeScreen` uses only `SimpleVpnController` and `/api/simple-vpn/config` provisioning.
- The active connect/disconnect button calls `NativeVpnService.connectAmneziaWg()` / `disconnectAmneziaWg()` directly through the embedded AmneziaWG runner.
- Old `VpnService` runtime pipeline is removed from the active path: no `/vpn/connect`, no protocol selector, no server selector, no old session/apply-state state machine, no old resume synchronization as the source of truth.
- On app resume, the clean screen only asks the native AmneziaWG runner whether the tunnel is up and mirrors that state best-effort.
- `ConnectionBlock` is in minimal button-only mode for the active VPN screen: speed/timeline/server/protocol UI is hidden because these controls belonged to the broken old state model.
- Xray/VLESS remains archived/R&D only and is not part of the active VPN path.

Validation:
- `flutter analyze` passed for the touched clean screen, shell, connection block, simple VPN controller/API, native VPN service, and `main.dart`; only pre-existing warnings/infos remained.
- Android debug build passed: `./gradlew :app:assembleDebug --no-daemon`.
- Flutter release build passed: `flutter build apk --release --no-tree-shake-icons`.

Release APK:
- URL: `https://api.granilink.com/downloads/grani-vpn-20260513-clean-awg-ui.apk`
- SHA256: `48c8a6758a7e59c83f922246eb8fd2288278bfef915f9900160d538a0b209bba`

Test focus:
- Install the clean APK.
- Login.
- Press the single connect button.
- Confirm YouTube loads.
- Put the app to background and return; the button must follow the native AmneziaWG state instead of triggering old sync errors.

## 2026-05-13 - Safe server/protocol controls added on top of clean AmneziaWG path

Reason:
- After the clean AmneziaWG build proved YouTube works, the next feature layer is server selection and a visible protocol selector.
- This must not reintroduce the old Grani `VpnService` state machine, old server selector, or old protocol bottom sheet.

Implemented backend:
- Added `GET /api/simple-vpn/servers`.
- It returns only active servers with `graniwg_enabled=true`; the selector is intentionally scoped to the proven AmneziaWG path.
- `GET /api/simple-vpn/config` now accepts optional `server_id` and provisions the AmneziaWG config for that selected server.
- If a device was previously bound to a different server, backend attempts to remove the old peer before adding the peer to the selected server.
- `/api/simple-vpn/protocols` still exposes the wider protocol registry, but the mobile clean UI filters the active selector to `graniwg` only.

Implemented mobile:
- `SimpleVpnApi` now supports `fetchServers()`, `fetchProtocols()`, and `fetchConfig(serverId: ...)`.
- `SimpleVpnController` stores selected server/protocol and passes selected `server_id` to `/simple-vpn/config`.
- `CleanAmneziaHomeScreen` now shows two selector chips under the main button:
  - server selector backed by `SimpleVpnController`, not `VpnService`;
  - protocol selector showing only `AmneziaWG` for now.
- Selectors are locked while connected/connecting/disconnecting to avoid mid-tunnel state churn.
- Old `ServerSelectorButton`, `ProtocolSelectorButton`, provider state, and legacy bottom sheets remain outside the active path.

Validation:
- `python3 -m py_compile backend/api/simple_vpn.py` passed.
- `flutter analyze lib/simple_vpn lib/screens/main/clean_amnezia_home_screen.dart --no-fatal-infos --no-fatal-warnings` passed.
- API container restarted and healthy.
- `GET /api/simple-vpn/servers` returns 401 without auth, confirming the route is active and protected.
- Flutter release build passed.

Release APK:
- URL: `https://api.granilink.com/downloads/grani-vpn-20260513-awg-server-protocol-select.apk`
- SHA256: `158892c9902dd6e387f6318c86316e51cac55884e65f118f07f43a7777fb0c70`

Test focus:
- Install APK, login.
- Before connecting, open server selector and choose a server.
- Open protocol selector; only AmneziaWG should be available.
- Connect and verify YouTube.
- Disconnect, choose another available server, connect again, verify YouTube.

## 2026-05-13 - Selector fix after failed connect test

User test of `awg-server-protocol-select`:
- VPN did not connect.
- Server list showed only Hungary.
- Protocol label should be `GRANIwg`, not `AmneziaWG`.
- Server localization needed cleanup.

Findings:
- Backend logs showed the app successfully loaded `/api/simple-vpn/servers`, `/api/simple-vpn/protocols`, and `/api/simple-vpn/config` for server 1 at 17:03 MSK.
- There was no subsequent `/api/simple-vpn/session/start` before the user reported failure, so the break happened after config fetch and before/around native start, not in server provisioning.
- DB server state explains the one-server list:
  - `HU-BUD-01` is active, `graniwg_enabled=true`, has WireGuard public key.
  - `UK-LON-01` is active but `graniwg_enabled=false` and has no WireGuard public key, so it is not safe to present as a working GRANIwg server yet.

Implemented:
- Clean connect path no longer waits for auxiliary `/session/start` before native AmneziaWG start.
- Native AmneziaWG is started immediately after `/simple-vpn/config`; `/session/start` and `/logs` are best-effort after native success.
- Protocol display name changed to `GRANIwg`.
- Server display localization improved for country/city names, including `Венгрия`, `Будапешт`, `Великобритания`, `Лондон`.
- Server selector still intentionally lists only working GRANIwg servers. UK must be configured as an AWG node before exposing it as selectable.

Validation:
- `flutter analyze lib/simple_vpn lib/screens/main/clean_amnezia_home_screen.dart --no-fatal-infos --no-fatal-warnings` passed.
- Flutter release build passed.

Release APK:
- URL: `https://api.granilink.com/downloads/grani-vpn-20260513-graniwg-selectors-fix.apk`
- SHA256: `c591dfd74ae28eacf6f60cd7e7e0f252627d0415ac4c5bbe24bf1e7467b3c7dc`

## 2026-05-14 - UK-LON-01 enabled as second GRANIwg server

Reason:
- After the clean GRANIwg selector build, the server list showed only Hungary because only `HU-BUD-01` had `graniwg_enabled=true` and a WireGuard public key.
- User asked to proceed with the next step: make the server selector useful by adding another working GRANIwg node.

Implemented on UK node:
- Connected through backend `SSHManager` using the existing server DB credentials; plain `ssh root@45.140.167.123` from backend host is not authorized.
- Installed `wireguard`, `wireguard-tools`, and best-effort AmneziaWG tools from the Amnezia PPA.
- Created `/etc/wireguard/wg0.conf` using the same runtime pattern as the working HU node:
  - `Address = 10.0.0.1/24`
  - `MTU = 1420`
  - `SaveConfig = false`
  - `ListenPort = 51820`
  - NAT/PostUp/PostDown on main interface `ens3`
- Enabled `net.ipv4.ip_forward=1`.
- Opened `51820/udp` through `ufw` if present.
- Started `wg0` and enabled `wg-quick@wg0` autostart.
- UK server public key: `AgIwKATpLE60rAXCk0gy0+gmDquEHAkXkzxrcn8R8ko=`.

Database changes:
- `UK-LON-01` now has:
  - `country = Великобритания`
  - `city = Лондон`
  - `graniwg_enabled = true`
  - `graniwg_obfuscation_type = amneziawg`
  - `graniwg_obfuscation_key = {"Jc":4,"Jmin":5,"Jmax":60}`
  - `wireguard_public_key = AgIwKATpLE60rAXCk0gy0+gmDquEHAkXkzxrcn8R8ko=`
  - `wireguard_port = 51820`
  - `wireguard_config_path = /etc/wireguard/wg0.conf`
  - `wireguard_interface = wg0`
  - `supported_protocols` includes `graniwg`.

Validation:
- Backend smoke provisioning against UK succeeded with test device `simple-awg-smoke-uk-20260514`:
  - generated a GRANIwg/AmneziaWG config;
  - allocated VPN IP `10.0.0.2`;
  - added peer to UK `wg0`;
  - then removed the smoke peer and deleted the test device.
- A leftover smoke peer without DB device was detected after the first removal attempt and was removed by public key to keep UK clean.
- Final `wg show wg0` on UK shows the interface up with public key `AgIwKATpLE60rAXCk0gy0+gmDquEHAkXkzxrcn8R8ko=` and no smoke peers.
- The simple server payload now contains two GRANIwg servers:
  - `HU-BUD-01` / `Будапешт, Венгрия` / `45.12.132.94`
  - `UK-LON-01` / `Лондон, Великобритания` / `45.140.167.123`

Operational note:
- No new APK was required. The latest selector build fetches `/api/simple-vpn/servers` dynamically, so after app restart/re-login it should show UK as the second GRANIwg server.
- Test focus: open latest `graniwg-selectors-fix` APK, refresh/restart app if needed, select `Лондон, Великобритания`, connect, verify YouTube.

## 2026-05-14 - Resume/cold-start route fallback fixed

User symptom:
- After the first app close/minimize, the app could show the global fallback screen: `Connection error. Check internet connection. / Try again`.
- This screen is not the GRANIwg tunnel state; it is the app-level initial route error screen from `main.dart`.

Root cause found:
- `GraniApp._determineInitialRouteInternal()` set the initial route and then called `_refreshControlPlaneInBackground()`.
- `_refreshControlPlaneInBackground()` tried to resolve `VpnService` via `Provider.of<VpnService>(context)` using the `GraniApp` context, which is above the `MultiProvider` that creates `VpnService`.
- On process recreation/resume this could throw during initial route determination, setting `_initialRouteError=true` and replacing the working VPN UI with the global connection-error screen.

Implemented:
- Initial route determination no longer depends on control-plane refresh or `VpnService` provider resolution.
- For an authenticated user, route determination timeout/error now falls back to cached `/main` instead of showing the global connection-error screen.
- Control-plane refresh is scheduled after the first frame and uses `appNavigatorKey.currentContext`, i.e. a context under `MultiProvider`.
- If `VpnService` is unavailable for background refresh, the app logs and keeps the cached route instead of showing the fatal fallback.
- Fixed a compile issue in `CleanAmneziaHomeScreen`: replaced invalid `Container(minHeight: 57)` with `constraints: BoxConstraints(minHeight: 57)`.

Validation:
- `flutter analyze lib/main.dart lib/screens/main/clean_amnezia_home_screen.dart --no-fatal-infos --no-fatal-warnings` passed with only pre-existing warnings/infos.
- Flutter release build passed.

Release APK:
- URL: `https://api.granilink.com/downloads/grani-vpn-20260514-resume-route-fallback-fix.apk`
- SHA256: `cada4c4364fcd477c1a4fa772f4e802640a6a5962f881df5757c57d7d5309694`

Test focus:
- Install APK, login, connect GRANIwg.
- Minimize/close/reopen the app once or several times.
- Expected: app returns to `/main` clean GRANIwg screen and does not show the global `Connection error` fallback while the user is authenticated.


## 2026-05-15 - Clean test baseline before next GRANIwg app test

Current active direction:
- Xray/VLESS remains archived/R&D only.
- Active client path is still the clean GRANIwg path: `CleanAmneziaHomeScreen` -> `SimpleVpnController` -> `/api/simple-vpn/config` -> native AmneziaWG runner.
- Latest APK for this round: `https://api.granilink.com/downloads/grani-vpn-20260514-resume-route-fallback-fix.apk`.

Server state before test:
- `HU-BUD-01` / `Будапешт, Венгрия` / `45.12.132.94` is online and `graniwg_enabled=true`.
- `UK-LON-01` / `Лондон, Великобритания` / `45.140.167.123` is online and `graniwg_enabled=true`.

Pre-test cleanup performed:
- OnePlus MT2111 public key `P79VMAjUVIrGR4mlXjvm1NxRaRPNiBXWtgDCu076SB8=` was found on both HU and UK, which makes server-switch test results invalid.
- Removed that peer from both GRANIwg servers and reloaded WireGuard.
- Reset device `id=213` to disconnected baseline: no `current_server_id`, no VPN IP, `vpn_protocol=graniwg`, `is_vpn_enabled=false`.

Test scenario for the next run:
1. Install/open `grani-vpn-20260514-resume-route-fallback-fix.apk`.
2. Make sure Android VPN key is gone. If it is still visible, disconnect the VPN from Android system UI or force-stop the app once.
3. Open the app and log in if needed.
4. Confirm the server selector shows both `Будапешт, Венгрия` and `Лондон, Великобритания`; protocol should be `GRANIwg`.
5. Select `Будапешт, Венгрия` first.
6. Tap connect once and wait up to 45 seconds. Do not tap repeatedly during provisioning.
7. Open YouTube and play a video for about 60 seconds.
8. Return to the app, verify the button/state did not fall into an error screen.
9. Minimize and reopen the app once; expected result is the clean GRANIwg screen, not the global `Connection error` fallback.
10. Disconnect and stop the test. Send logcat.

Important:
- Do not test HU -> UK -> HU switching in the same run yet. The current target is clean baseline validation on one server.
- After HU passes, run London as a separate clean test from disconnected state.
- If switching still becomes a product requirement, fix only the minimal server-switch atomicity: pre-connect native disconnect, longer config timeout, per-device backend lock, and peer cleanup by public key. Do not restore old sessions/apply-state/COMMIT pipeline.


## 2026-05-15 - Test log `OnePlus-MT2111-Android-14_2026-05-15_134746.logcat`

User report:
- After the clean baseline reset, the test looked mostly OK except the first connection.

Observed from backend logs:
- `13:46:01 MSK`: `/api/simple-vpn/config` succeeded for `server_id=1` / HU in `10726.9ms`, followed by successful `/api/simple-vpn/session/start`.
- `13:46:52 MSK`: user stop succeeded.
- `13:47:04 MSK`: `/api/simple-vpn/config` succeeded for `server_id=3` / UK in `8104.1ms`, followed by successful `/api/simple-vpn/session/start`.
- `13:47:42 MSK`: user stop succeeded.
- `13:48:50 MSK`: `/api/simple-vpn/config` succeeded again for `server_id=3` / UK in `8050.9ms`, followed by successful `/api/simple-vpn/session/start`.

Observed from Android logcat:
- The attached logcat starts after the UK tunnel was already up, so it does not contain the first HU connect attempt itself.
- During the recorded window, Android had an active VPN network, YouTube opened, loaded media, and reached player `onPlaying` around `13:47:18 MSK`.
- App resume/cold-start fallback behaved correctly: authenticated fallback routed to `/main`, not the old global `Connection error` screen.
- User disconnect around `13:47:39 MSK` cleanly brought AmneziaWG down and Android VPN transitioned to disconnected.

Remaining defect found after the test:
- The OnePlus public key `P79VMAjUVIrGR4mlXjvm1NxRaRPNiBXWtgDCu076SB8=` is present in both HU and UK WireGuard configs after the HU -> UK test flow.
- DB points the device to UK (`current_server_id=3`, `ip_address=10.0.0.2`, `vpn_protocol=graniwg`, `is_vpn_enabled=true`), but stale HU peer remains.
- Conclusion: normal connect/disconnect and resume are working much better, but server-switch cleanup is still incomplete. The next code fix should be minimal switch atomicity only: remove stale peers by public key from all non-selected GRANIwg servers during `/simple-vpn/config`; do not reintroduce old sessions/apply-state/COMMIT pipeline.


## 2026-05-15 - GRANIwg multi-server prepared peer cache

Reason:
- User clarified that slow first connection is acceptable, but repeat connections should use cache.
- Desired model: after a phone has connected to HU and UK once, both server profiles should remain prepared so reconnecting to either server can be local/fast.
- Therefore, a peer existing on multiple servers is no longer automatically a bug if it is tracked as an intentional prepared peer.

Backend changes:
- `/api/simple-vpn/config` now uses a new lightweight prepared-peer model instead of treating `devices.current_server_id/ip_address` as the only source of truth.
- Added on-demand table `device_server_peers` with one row per `(device_id, server_id, protocol)`:
  - `device_id`, `server_id`, `protocol`, `public_key`, `vpn_ip`, `config_revision`, timestamps, `revoked_at`.
- Added per-device in-process provisioning lock for `/simple-vpn/config` to avoid duplicate provisioning from repeated taps.
- First config request for a server creates a peer on that server and records it in `device_server_peers`.
- Later config requests for the same device/server reuse the prepared row and return config with `json_config.source=prepared-peer-cache`.
- `devices.current_server_id/ip_address` is now treated as last/active selected server metadata, not the complete list of prepared peers.
- Existing OnePlus MT2111 prepared rows seeded:
  - server 1 / HU: `10.0.0.2`, public key `P79VMAjUVIrGR4mlXjvm1NxRaRPNiBXWtgDCu076SB8=`.
  - server 3 / UK: `10.0.0.2`, same device public key.

Mobile changes:
- `SimpleVpnApi.fetchConfig()` receive timeout increased from 12s to 45s for first provisioning.
- `SimpleVpnConfig` and `SimpleVpnServer` can now serialize to local cache.
- `SimpleVpnController` stores GRANIwg configs in local cache by `deviceId + protocol + serverId`, TTL 7 days.
- Repeat connect uses cached AmneziaWG config without calling `/simple-vpn/config`.
- If cached native start fails, the app deletes only that server cache entry, fetches a fresh config once, caches it, and retries native start.
- Before native connect the controller does a local best-effort `disconnectAmneziaWg(reason=before_connect)` to avoid two local Android VPN starts colliding. This does not call the old Grani pipeline.

Validation:
- `python3 -m py_compile backend/api/simple_vpn.py` passed.
- `/opt/flutter/bin/flutter analyze lib/simple_vpn --no-fatal-infos --no-fatal-warnings` passed.
- Flutter release build passed.
- Published APK URL: `https://api.granilink.com/downloads/grani-vpn-20260515-graniwg-multiserver-cache.apk`.
- SHA256: `ec5426bcedb4ba5be5215ebab8bf9f9fd618ef7f13549018207cffa4ac0a9d56`.
- URL returns HTTP 200.
- Backend smoke verified both HU and UK return `prepared-peer-cache` for OnePlus with `10.0.0.2`.

Next test scenario:
1. Install `grani-vpn-20260515-graniwg-multiserver-cache.apk`.
2. Select HU, connect once, verify YouTube, disconnect.
3. Select UK, connect once, verify YouTube, disconnect.
4. Select HU again and connect. Expected: mobile log should include `config_cache_hit`; backend should not need a new `/simple-vpn/config` for that server if local cache exists.
5. Repeat UK. Expected: cached local connect.
6. Send logcat. Backend logs should be checked for fewer `/api/simple-vpn/config` calls on repeat connects.

Split tunneling note:
- Not implemented in this change.
- Recommended next step: treat split tunneling as local Android VPN config mutation over cached GRANIwg config. It may require a local tunnel restart, but should not require backend provisioning or server peer changes.


## 2026-05-15 - Test log `OnePlus-MT2111-Android-14_2026-05-15_145138.logcat`

User report:
- HU first connect: app/VPN formally connected, YouTube failed. User suspects missing Android VPN permission popup on first attempt.
- UK connect: YouTube opened/played.
- HU repeat: connected, YouTube failed again.
- UK repeat: connected, YouTube opened. Asked whether it used cache or backend.

Backend timeline:
- `14:49:51 MSK`: `/api/simple-vpn/config` for HU `server_id=1`; backend reported `prepared-peer-cache`, `vpn_ip=10.0.0.2`, request took ~55ms.
- `14:49:54 MSK`: session start for HU.
- `14:50:22 MSK`: session stop.
- `14:50:28 MSK`: `/api/simple-vpn/config` for UK `server_id=3`; backend reported `prepared-peer-cache`, `vpn_ip=10.0.0.2`, request took ~44ms.
- `14:50:29 MSK`: session start for UK.
- `14:50:47 MSK`: session stop.
- `14:50:51 MSK`: session start only, no `/api/simple-vpn/config`; this means repeat connect used mobile local cache.
- `14:51:21 MSK`: session start only, no `/api/simple-vpn/config`; this means repeat connect used mobile local cache.
- `14:51:33 MSK`: session stop.

Android logcat scope:
- Attached logcat only covers `14:51:11` to `14:51:42 MSK`, so it contains only the final UK playback/disconnect window, not the first HU/UK attempts.
- In the recorded window YouTube reaches `onPlaying` at `14:51:29`, so final UK worked.
- Final disconnect shows active peer `AgIw…R8ko`, which is UK server public key, confirming final tunnel was UK.

Root cause found for HU failures:
- DB/prepared-peer table says HU prepared VPN IP is `10.0.0.2`.
- Actual runtime `wg show` on HU for OnePlus public key says `AllowedIPs = 10.0.0.10/32`.
- Actual runtime `wg show` on UK for the same key says `AllowedIPs = 10.0.0.2/32`.
- Therefore HU client config generated from DB/cache uses `Address = 10.0.0.2/32`, but HU server routes the phone peer as `10.0.0.10/32`.
- This mismatch explains “VPN connected formally, YouTube fails” on HU: handshake may exist, but tunnel IP/routing is wrong for returned traffic.
- The Android permission-popup suspicion is not the main explanation for repeated HU failure, because HU failed again after VPN permission/state existed.

Next fix needed:
- Add prepared-peer reconciliation: backend must verify that DB/prepared peer IP matches the actual server peer for that public key before returning/caching config.
- For HU specifically, either update HU server peer to `10.0.0.2/32` to match DB/cache, or update DB/cache to `10.0.0.10` and invalidate the stale mobile HU cache. Prefer server-side reconcile to DB/table IP so both HU and UK stay simple for the client.
- Add a `config_revision` bump when a prepared peer is reconciled, so mobile does not keep using stale cached HU config.


## 2026-05-15 - Test log `OnePlus-MT2111-Android-14_2026-05-15_150405.logcat`

User report:
- Retested cleanly under another account.
- Overall flow was smooth; one disconnect felt long.
- Asked whether repeat connects used cache.

Backend observations:
- New active simple device: user `23`, device DB id `92`, device_id `6863a2f9-cbf8-499e-8c8c-aead6a43f34d`, public key `JwQ5HMOjk9PaShhAsBzw64M4qMXtgcp6L/M9MMotbBk=`.
- First HU connect:
  - `15:02:06 MSK`: prepared peer created on HU `server_id=1`, VPN IP `10.0.0.9`, `/simple-vpn/config` took `10501.5ms`.
  - `15:02:07 MSK`: session start.
  - `15:02:27 MSK`: session stop, fast.
- First UK connect:
  - `15:02:39 MSK`: prepared peer created on UK `server_id=3`, VPN IP `10.0.0.3`, `/simple-vpn/config` took `8098.1ms`.
  - `15:02:40 MSK`: session start.
- Repeat connects:
  - `15:03:14 MSK`: session start only, no `/simple-vpn/config` -> local mobile cache was used.
  - `15:03:36 MSK`: session start only, no `/simple-vpn/config` -> local mobile cache was used.
  - Stops at `15:03:29` and `15:03:53` were fast on backend.
- The `15:02:40` UK session id `944f61ff...` has no matching `/simple-vpn/session/stop` in backend logs; this likely corresponds to the disconnect that felt long or got superseded by the next connect. Native pre-connect disconnect still prevented local tunnel collision.

Server/runtime verification:
- HU runtime peer for new key: `AllowedIPs=10.0.0.9/32`, matching DB/prepared peer.
- UK runtime peer for new key: `AllowedIPs=10.0.0.3/32`, matching DB/prepared peer.
- Unlike the previous user-1 test, there is no HU DB/server IP mismatch for this new account.

Android logcat scope:
- Attached logcat covers only `15:03:41-15:04:09 MSK`, so it contains the final UK disconnect tail, not the whole test.
- Final native disconnect is fast in logcat: `disconnectAmneziaWg` at `15:03:50.648`, tunnel `DOWN` at `15:03:50.738`.

Conclusion:
- Multi-server prepared peer model works correctly for a fresh account.
- Repeat connections did use mobile local cache.
- Remaining cleanup item: session bookkeeping can miss a stop when user disconnects/reconnects quickly; not critical for the tunnel, but should be made more consistent later.

## Обновление 2026-05-15: node-verified analytics + split tunnel cache path

- `session_stop` намеренно не менялся: текущая задача только аналитика фактического успеха и возврат split tunnel.
- Добавлен backend endpoint `POST /api/simple-vpn/session/verify`:
  - принимает `device_id`, `session_id`, `server_id`, `protocol`;
  - по выбранному серверу через SSH читает `wg show wg0 dump`;
  - проверяет peer телефона по public key, совпадение `AllowedIPs` с prepared `vpn_ip`, свежий handshake (`<=60s`) и наличие rx/tx counters;
  - возвращает `verified/unverified` и детали (`handshake_age_sec`, `rx_bytes`, `tx_bytes`, `reason`).
- Mobile после успешного native GRANIwg connect и `session/start` запускает фоновую проверку node traffic:
  - VPN не роняется и UI не зависит от результата проверки;
  - если backend вернул `verified=true`, Firebase Analytics получает событие `vpn_data_verified`;
  - параметры события: `server_id`, `protocol`, `from_cache`, `session_id`, `handshake_age_sec`, `rx_bytes`, `tx_bytes`.
- Повторные подключения по-прежнему используют локальный config cache; проверка node traffic не дергает `/simple-vpn/config`.
- Split tunnel для GRANIwg оставлен локальным:
  - выбранные приложения сохраняются в native prefs;
  - при следующем ручном подключении `SimpleAmneziaWgRunner` добавляет `ExcludedApplications` или `IncludedApplications` в cached config перед стартом туннеля;
  - backend/server peer при этом не пересоздается.
- Сообщение split tunnel уточнено: изменения сохранены, нужно вручную отключить и подключить VPN для применения.
- В connected-hint split tunnel теперь проверяется `getAmneziaWgStatus()`, а не старый `getStatus()` legacy VPN.
- Доменные правила пока только сохраняются локально; для GRANIwg активный надежный split tunnel сейчас per-app, без изменения server peer.


## Обновление 2026-05-15: session id до native-start + download APK

User report:
- First connect worked and YouTube opened.
- After phone/app went to background, reopening YouTube did not work.
- Expected Analytics event for successful verified connect did not appear.

Log/backend findings:
- Android log shows AmneziaWG tunnel went `UP`, received handshake response, and continued receiving keepalive packets while app was in background.
- Therefore the peer/tunnel itself did not obviously die in background; next test should inspect app traffic/RX/TX/routes/DNS if YouTube fails again.
- Backend logs for the reported window had `/api/simple-vpn/session/start` and `/session/stop`, but no `/session/verify` and no `node_data_verified` / `vpn_data_verified` client log.
- Root cause for missing Analytics: `SimpleVpnController` created `/simple-vpn/session/start` after native AmneziaWG start, so native logs showed `startAmneziaWgConnection ... session=null`; node verification was a single delayed background task and could be skipped/lost when app went background.

Fix implemented:
- `mobile-app/lib/simple_vpn/simple_vpn_controller.dart` now calls `/simple-vpn/session/start` before native connect and passes `connection_session_id` into `connectAmneziaWg`.
- Node traffic verification is now retried at `2s -> 4s -> 8s` while the same session remains connected.
- On verified result, mobile sends backend client log event `vpn_data_verified` and then Firebase Analytics event `vpn_data_verified` once per session.
- On app resume/native state sync, mobile schedules a catch-up verification if tunnel is still connected and the current session was not verified yet.
- If native connect fails after session creation, mobile best-effort stops the session with reason `connect_failed`.

Verification:
- `/opt/flutter/bin/dart analyze mobile-app/lib/simple_vpn/simple_vpn_controller.dart` -> no issues found.
- `/opt/flutter/bin/flutter build apk --release` -> success.
- APK artifact: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`.
- Published APK: `https://api.granilink.com/downloads/grani-vpn-20260515-session-analytics-fix.apk?cb=20260515-session`.
- Stable latest APK alias updated: `https://api.granilink.com/downloads/app-release.apk?v=20260515-session-analytics-fix`.
- SHA256: `f7bf4486bdef6b2e197d38f8138c4f06221b8342e818cae94d7a1fd0903bbe3d`.
- Download check: both URLs return HTTP 200, content-type `application/vnd.android.package-archive`, content-length `87214608`, Cloudflare `cf-cache-status: BYPASS`.

Next test expectations:
- Native log should show `startAmneziaWgConnection: source=simple_vpn session=<uuid>` instead of `session=null`.
- Backend should receive `/api/simple-vpn/session/verify` after connect or after resume catch-up.
- If traffic is verified, backend log should include `simple-vpn client-log ... event=vpn_data_verified` and Firebase Analytics should receive `vpn_data_verified`.
- If YouTube fails while keepalives continue, use verify details (`rx_bytes`, `tx_bytes`, `handshake_age_sec`, `reason`) plus Android route/DNS/app traffic logs to separate tunnel liveness from app-data routing failure.

## Обновление 2026-05-18: cache/config reconcile + session guard

Симптом из логов 2026-05-18 11:39 MSK: AmneziaWG tunnel поднимается, handshake response приходит, keepalive идут, но пользовательский трафик не работает после ухода приложения в фон/возврата. В Android log видно `startAmneziaWgConnection: source=simple_vpn session=null`, то есть native connect мог стартовать без backend session id. В backend в этот момент не было нового `/simple-vpn/session/start`, поэтому analytics/verify тоже не могли корректно привязаться к подключению.

Корневая причина для user_id=1/device `a0e7e44b-e62b-48e6-9345-cb87a0647852` на HU-BUD-01: локальный/DB config использовал `Address=10.0.0.2/32`, а runtime на сервере для того же public key держал peer с `allowed_ips=10.0.0.10/32`. Handshake при таком расхождении живой, но полезный трафик не маршрутизируется обратно на IP клиента. Это объясняет состояние "подключение есть, ничего не работает".

Что сделано:
- Backend `backend/api/simple_vpn.py`: перед выдачей AmneziaWG profile теперь сверяет prepared peer в DB с runtime `wg show`/node verification. Если runtime вернул `allowed_ip_mismatch`, backend reconciliation обновляет `device_server_peers.vpn_ip` и `profile_revision` на фактический runtime IP, затем возвращает согласованный config. Для HU-BUD-01 peer user1 был reconciled с `10.0.0.2` на `10.0.0.10`.
- Mobile `mobile-app/lib/simple_vpn/simple_vpn_controller.dart`: cache key поднят до `simple_vpn_config_v3`, чтобы старые cached configs не использовались после исправления. Native connect теперь hard-fail при отсутствии `session_id`, вместо старого поведения `session=null`.
- Версия APK поднята до `1.0.4+24`.
- Backend container `granivpn_api` перезапущен и healthy.

Сборка для проверки:
- Direct APK: `https://api.granilink.com/downloads/grani-vpn-20260518-cache-reconcile-fix.apk?cb=20260518-cache`
- Stable APK: `https://api.granilink.com/downloads/app-release.apk?v=20260518-cache-reconcile-fix`
- SHA256: `7fb74344a72aec6c7029dbd61b090f4f96ec78093f7e3338e70e16d393f3ad85`

Финальное правило подключения для всех серверов:
1. Cache должен быть scoped по `(device_id, protocol, server_id)`. Первое подключение к конкретному серверу идет через backend config/profile endpoint и сохраняет config в local cache. Повторное подключение к тому же серверу использует cache.
2. Backend остается source of truth при первом config fetch и при forced refresh. Перед возвратом config backend обязан reconcile DB prepared peer с runtime node state, чтобы `Address` клиента совпадал с `AllowedIPs` peer на сервере.
3. Mobile не имеет права стартовать native VPN без успешного `/simple-vpn/session/start` и `session_id`.
4. Для окончательной защиты от stale cache нужно добавить в `/session/start` или `/session/verify` передачу client-side `config_revision`/`vpn_ip`. Если backend видит mismatch с актуальным prepared peer/runtime, он должен вернуть `config_stale`; mobile инвалидирует cache, один раз refetch config через backend и повторяет connect. Это закрывает случай, когда старый APK/старый cache пережил backend reconcile.

## Обновление 2026-05-18: production domain split tunnel для GRANIwg

Пользователь протестировал app split tunnel на HU-BUD-01: выбранное приложение корректно уходит в обход VPN, остальные приложения остаются в VPN. Это подтверждает, что app-based split tunnel работает штатно.

Новый блокер: пользователь добавил домен `2ip.ru`, переподключился к GRANIwg, но сайт продолжил видеть Венгрию/Будапешт. Причина: текущая AmneziaWG/GRANIwg ветка применяет только app-based split через `ExcludedApplications`/`IncludedApplications`. Список `split_tunnel_direct_domains` сохраняется и передается в `connectAmneziaWg`, но `SimpleAmneziaWgRunner` его не применяет. Domain routing сейчас фактически есть только в Xray pipeline (`XrayRoutingHelper`), не в AmneziaWG.

Принятое production-направление для GRANIwg без второго VPN engine:
- не пытаться вставлять домены напрямую в WireGuard config, потому что WireGuard/AmneziaWG маршрутизирует IP, а не домены;
- перед стартом GRANIwg читать `SplitTunnelPrefs.getDirectDomains(context)`;
- нормализовать домены: lowercase, IDN/punycode, убрать схему/путь, поддержать базовый exact/root + `www.` вариант;
- резолвить домены в IP перед connect;
- кешировать domain->IP с TTL, чтобы повторный connect не зависел полностью от DNS;
- строить `AllowedIPs` как full-tunnel minus resolved direct IPs, то есть direct-домены уходят мимо VPN на уровне маршрутизации Android/WireGuard;
- если резолв не удался или список IP пустой, не ломать VPN: оставить исходный config и записать diagnostic warning;
- ограничить число исключаемых IP и логировать: domains_count, resolved_ips_count, cache_hit/cache_miss, applied/skipped reason;
- IPv4 реализовать первым; IPv6 либо отключить/не анонсировать до полной проверки, либо поддержать отдельным этапом через IPv6 complement;
- wildcard/subdomain/CDN в production требует DNS-observer/refresh или отдельный domain-aware engine (sing-box/Xray). Первый рабочий слой покрывает exact/root/www и типовые сайты вроде `2ip.ru`.

Важно по UX:
- app split tunnel: выбранное приложение идет в обход VPN в режиме `exclude`;
- domain split tunnel: выбранные домены идут в обход VPN для всех приложений, но только после успешного DNS->IP resolve и reconnect;
- для Chrome с DoH/Private DNS нужно показывать предупреждение: браузер может резолвить домен иначе, чем системный резолвер, поэтому проверочный домен может потребовать выключить Chrome Secure DNS/Android Private DNS или использовать app split для браузера целиком.

Требование пользователя: все этапы фиксировать в этом контексте. APK не собирать без явной команды пользователя.

### Реализация первого слоя GRANIwg domain-direct — 2026-05-18

Изменен `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/SimpleAmneziaWgRunner.kt`:
- `applySplitTunnelPrefs()` теперь применяет два независимых слоя:
  1. app split tunnel через `IncludedApplications`/`ExcludedApplications`;
  2. domain direct bypass для GRANIwg.
- Domain bypass читает `SplitTunnelPrefs.getDirectDomains(context)`.
- Для каждого домена пробует exact/root и `www.` вариант.
- Резолвит только публичные IPv4 через системный resolver.
- Кеширует `host -> ips` в `SharedPreferences(grani_vpn_prefs)` под ключом `split_tunnel_domain_ip_cache_v1`, TTL 6 часов.
- Если IP найдены, заменяет peer `AllowedIPs = 0.0.0.0/0` на набор CIDR `0.0.0.0/0 minus resolved_direct_ips`; сохраненные IPv6/прочие AllowedIPs не удаляются.
- Ограничения безопасности: максимум 16 direct IP и максимум 640 CIDR, иначе domain bypass не применяется, чтобы не сломать tunnel.
- Fallback: если домены не резолвятся, `[Peer]`/`AllowedIPs` не найдены, либо config не full-tunnel IPv4, исходный config остается без изменений.
- Диагностика в logcat:
  - `split tunnel domains: resolve domains=... ipv4=... cache_hits=... cache_misses=...`
  - `split tunnel domains: applied domains=... resolved_ipv4=... cidrs=...`
  - skip reasons: `no resolved IPv4`, `AllowedIPs not found`, `not IPv4 full-tunnel`, `cidr_count...`.

Проверка:
- Запущена только компиляция Kotlin, без сборки APK: `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin`.
- Результат: `BUILD SUCCESSFUL`.
- APK по требованию пользователя не собирался.

Ожидаемый тест после будущей APK-сборки:
1. Split tunnel domains: добавить `2ip.ru`, приложения не отмечать.
2. Подключиться к HU GRANIwg.
3. В logcat ожидать `split tunnel domains: applied ...`.
4. Открыть `2ip.ru` в Chrome. Если Chrome Secure DNS/Android Private DNS выключены или совпадают с системным resolver, сайт должен идти direct и показать не Венгрию.
5. Проверить другой сайт, не добавленный в domains: он должен оставаться через VPN и показывать Венгрию.
6. Если `2ip.ru` все равно через VPN, собрать logcat по строкам `split tunnel domains` и проверить, какие IP были resolved/cached; возможная причина — Chrome DoH/Private DNS или CDN-IP не совпал с системным resolve на момент connect.

### Дополнение UI/native для domain split — 2026-05-18

Изменены файлы:
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/SplitTunnelPrefs.kt`
- `mobile-app/lib/screens/split_tunnel_screen.dart`
- `mobile-app/lib/l10n/app_ru.arb`
- `mobile-app/lib/l10n/app_en.arb`
- `mobile-app/lib/l10n/app_localizations_ru.dart`
- `mobile-app/lib/l10n/app_localizations_en.dart`

Что добавлено:
- Native-нормализация direct domains теперь принимает URL-like ввод: убирает схему, путь, query/fragment, userinfo, порт, ведущие/хвостовые точки.
- Native поддерживает IDN через `IDN.toASCII(..., USE_STD3_ASCII_RULES)` и wildcard-форму `*.example.com`.
- UI перед сохранением нормализует типовые ASCII-домены, чтобы `https://2ip.ru/path` превращался в `2ip.ru`.
- На экране split tunnel добавлена подсказка: domain bypass применяется после переподключения, домены резолвятся в IP и кешируются на устройстве; для Chrome нужно выключить Secure DNS, а на Android — Private DNS, иначе браузер может получить другой IP и проверка будет выглядеть как "не работает".

Проверка:
- `dart format` для измененных Dart-файлов выполнен.
- `dart analyze mobile-app/lib/screens/split_tunnel_screen.dart`: ошибок нет; остались только существующие info-подсказки линтера (`use_build_context_synchronously`, `prefer_const_constructors`).
- `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin`: `BUILD SUCCESSFUL`.
- APK не собирался.

## Заметка 2026-06-02: монохромная favicon G для granilink.com

- Для известных доменов/поддоменов `granilink.com` добавлена единая монохромная favicon на базе фирменной G:
  - основной домен: `granilink.com`, `www.granilink.com`;
  - API: `api.granilink.com`;
  - админка: `admin.granilink.com`;
  - app-прокси: `app.granilink.com`.
- Сгенерирован favicon pack в одном цвете `#192F3F`:
  - `favicon.ico`;
  - `favicon.png`;
  - `favicon-32.png`;
  - `favicon-16.png`;
  - `apple-touch-icon.png`;
  - `android-chrome-192x192.png`;
  - `android-chrome-512x512.png`.
- Файлы разложены в:
  - `server-config/static-pages/` для root/API/app exact favicon responses;
  - `admin-panel/public/` для исходного template админки;
  - `admin-panel/build/` для текущей опубликованной сборки админки.
- В HTML добавлены/обновлены favicon links:
  - `server-config/static-pages/index.html`;
  - `server-config/static-pages/privacy.html`;
  - `admin-panel/public/index.html`;
  - `admin-panel/build/index.html`.
- В `server-config/nginx/nginx.conf` добавлены exact/static favicon locations для HTTPS blocks:
  - root/www и api отдают favicon из `/var/www/granivpn/static-pages`;
  - admin отдает favicon из `/var/www/granivpn/admin-build`;
  - app, несмотря на Netlify proxy, перехватывает `/favicon.ico`, `/favicon.png`, `/favicon-32.png`, `/favicon-16.png`, `/apple-touch-icon.png`, `/android-chrome-192x192.png`, `/android-chrome-512x512.png` локально из static-pages.
- Проверки:
  - `docker exec granivpn_nginx nginx -t` — syntax ok, test successful; старые warnings про `listen ... http2` и duplicate `admin/app` server names остаются;
  - `docker exec granivpn_nginx nginx -s reload` — выполнен;
  - `curl -I` вернул `HTTP/2 200` для:
    - `https://granilink.com/favicon.ico`;
    - `https://www.granilink.com/favicon.ico`;
    - `https://api.granilink.com/favicon.ico`;
    - `https://admin.granilink.com/favicon.ico`;
    - `https://app.granilink.com/favicon.ico`;
    - `https://granilink.com/favicon-32.png`;
    - `https://app.granilink.com/apple-touch-icon.png`.
- HTML-проверка показала favicon links на `granilink.com/`, `www.granilink.com/privacy`, `admin.granilink.com/`; `app.granilink.com/` продолжает отдавать Netlify HTML, но относительный `favicon.png` теперь обслуживается локальным nginx exact/static route.

## Обновление 2026-05-19: launcher/adaptive icon v21

Пользователь подтвердил:
- новую картинку использовать только как Launcher Icon / Adaptive foreground;
- фон adaptive icon оставить светлым;
- Monochrome Icon и Notification Small Icon брать из текущей монохромной иконки, которая уже используется в уведомлениях и быстрой кнопке.

Что сделано:
- Источник foreground: `C:/Users/railt/Downloads/иконка22.png`.
- Сгенерированы Android-ресурсы в `launcher_icon_v3`.
- На сервере `/opt/grani/mobile-app` заменены:
  - `android/app/src/main/res/drawable-*/ic_launcher_foreground.png`
  - `android/app/src/main/res/mipmap-*/ic_launcher.png`
  - `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`
- Adaptive icon теперь:
  - `background`: `@color/ic_launcher_background`
  - `foreground`: `@drawable/ic_launcher_foreground`
  - `monochrome`: `@drawable/ic_notification_g`
- `ic_notification_g.xml` не менялся и остается общей монохромной иконкой для уведомлений, quick tile и themed/monochrome launcher.

Проверка:
- `cd /opt/grani/mobile-app/android && ./gradlew :app:processReleaseResources --offline --no-daemon`: `BUILD SUCCESSFUL`.

Важно:
- APK/AAB после замены foreground на `иконка22.png` еще не собирались. Последние опубликованные v21 APK/AAB были собраны до этой иконки.

## Обновление 2026-05-19: пересборка APK/AAB с versionCode 21

Собрана новая release-сборка после смены версии на `1.0.4+21`.

Подтвержденные версии:
- `pubspec.yaml`: `version: 1.0.4+21`
- `android/local.properties`: `flutter.versionName=1.0.4`, `flutter.versionCode=21`
- `VpnService.CODE_VERSION`: `2026-05-19-v21-0758017`

Публичные ссылки:
- APK: `https://api.granilink.com/downloads/grani-vpn-20260519-full-cycle-v21.apk`
- AAB: `https://api.granilink.com/downloads/grani-vpn-20260519-full-cycle-v21.aab`
- SHA256: `https://api.granilink.com/downloads/grani-vpn-20260519-full-cycle-v21.sha256`

SHA256:
- APK: `b23a315268309af51679febdfb8cf0d7d08999fac6577d570166ce15aa07a028`
- AAB: `c7f2d11fc26bbee8f2d8f4fe2897550b7c68c2b6b6bb25bcf48379594a113b7f`

Проверка:
- Все три URL вернули HTTP `200`.
- Размеры: APK около `84M`, AAB около `66M`.

Важно:
- Для Google Play `versionCode` должен быть строго выше уже загруженной в Play Console версии. Если в Play уже была загружена сборка с `versionCode > 21`, AAB с `21` будет отклонен.

## Обновление 2026-05-19: launcher/adaptive icon переделана правильно

Проблема:
- Предыдущая launcher icon была обычным квадратным PNG с белым фоном внутри.
- Android дополнительно маскировал этот квадрат, поэтому на рабочем столе знак выглядел крупным/прижатым и визуально обрезанным.

Что сделано из `C:\Users\railt\Downloads\иконка2.png`:
- Отделен знак `G/щит` от белого фона.
- `ic_launcher_foreground.png` теперь прозрачный foreground: только знак без собственного белого квадрата.
- `mipmap-*/ic_launcher.png` fallback для старых Android пересобран как аккуратная композиция: светлый фон + знак с safe padding.
- Добавлен `drawable/ic_launcher_monochrome.png`.
- `mipmap-anydpi-v26/ic_launcher.xml` теперь содержит:
  - `background` = `@color/ic_launcher_background`
  - `foreground` = `@drawable/ic_launcher_foreground`
  - `monochrome` = `@drawable/ic_launcher_monochrome`

Не менялось:
- `drawable/ic_notification_g.xml` оставлен прежним для notification small icon.

Проверка:
- `cd /opt/grani/mobile-app/android && ./gradlew :app:processReleaseResources --offline --no-daemon`: `BUILD SUCCESSFUL`.
- APK/AAB после этой иконки не пересобирались.

## Обновление 2026-05-19: сборка для полного пользовательского цикла

Цель: дать тестовую сборку для полного цикла пользователя: регистрация, trial, подключение, оплата/подписка, устройства, split tunneling, quick tile, уведомления.

Версия сборки:
- `pubspec.yaml`: `1.0.4+25`
- `android/local.properties`: `flutter.versionName=1.0.4`, `flutter.versionCode=25`
- `VpnService.CODE_VERSION`: `2026-05-19-v25-0758017`

Собрано:
- APK: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`
- AAB: `/opt/grani/mobile-app/build/app/outputs/bundle/release/app-release.aab`

Публичные ссылки:
- APK для установки на устройство: `https://api.granilink.com/downloads/grani-vpn-20260519-full-cycle-v25.apk`
- AAB для Google Play/internal testing: `https://api.granilink.com/downloads/grani-vpn-20260519-full-cycle-v25.aab`
- SHA256: `https://api.granilink.com/downloads/grani-vpn-20260519-full-cycle-v25.sha256`

SHA256:
- APK: `7512e869c26ec684e4305b6168676305f5ed66c5b111d250057663f05880ec2d`
- AAB: `d1a47f8851249a282d471f82dc523f88dea465122969104b410f97923d6f9c57`

Проверка доступности:
- Все три URL (`apk`, `aab`, `sha256`) вернули HTTP `200`.

Примечание:
- Первый вариант имени `grani-vpn-1.0.4-25.apk` попал под Cloudflare 404 cache после ранней проверки до копирования файла, поэтому для теста выдано новое уникальное имя `grani-vpn-20260519-full-cycle-v25.*`.

## Обновление 2026-05-19: версия приложения выставлена на build 21

По просьбе пользователя версия синхронизирована на `21` везде:
- `mobile-app/pubspec.yaml`: `version: 1.0.4+21`
- `mobile-app/android/local.properties`: `flutter.versionName=1.0.4`, `flutter.versionCode=21`
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt`: `CODE_VERSION = "2026-05-19-v21-0758017"`

Важно:
- Для Google Play `versionCode` должен быть строго выше уже загруженной в Play Console версии. Если в Play уже была загружена сборка с `versionCode > 21`, AAB с `21` будет отклонен.
- После смены версии APK/AAB не пересобирались в этом шаге.

## Обновление 2026-05-19: иконка системных сообщений быстрой плитки

Пользователь показал системный пузырь Android/Oplus с текстом `Требуется активная подписка...`, где рядом отображалась старая цветная иконка приложения.

Разбор:
- VPN foreground notification уже использует монохромный ресурс `R.drawable.ic_notification_g`.
- Quick Settings tile тоже использует `R.drawable.ic_notification_g`.
- FCM/default/local notifications тоже настроены на `@drawable/ic_notification_g`.
- Проблемный пузырь был не notification, а native `Toast` из `QuickTileService`/`QuickTileToggleActivity`.
- На новых Android/OEM Toast автоматически показывает launcher icon приложения, поэтому там появлялась старая цветная иконка. Это не управляется `setSmallIcon`.

Что сделано:
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/QuickTileService.kt`
  - Добавлен `showQuickTileNotice(...)`.
  - Сообщения быстрой плитки теперь показываются через системное notification с:
    - `setSmallIcon(R.drawable.ic_notification_g)`
    - отдельным channel `grani_quick_tile`
    - tap intent в `/main` или `/subscription`.
  - Если `POST_NOTIFICATIONS` не выдан на Android 13+, сообщение тихо пропускается, чтобы не возвращать старый Toast с цветной иконкой.
  - Toast удален для случаев:
    - нет активной подписки/триала;
    - нет сохраненного конфига;
    - ошибка старта cached config.
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/QuickTileToggleActivity.kt`
  - Toast при отсутствии cached config заменен на `QuickTileService.showQuickTileNotice(...)`.

Важно:
- `android:icon="@mipmap/ic_launcher"` не менялся, чтобы не заменить launcher icon приложения на рабочем столе без отдельного решения по брендингу.
- Системный экран настроек уведомлений Android может показывать именно app icon в заголовке приложения; actual notification small icon теперь остается монохромным.

## Обновление 2026-05-19: новая Launcher Icon приложения

Пользователь подтвердил:
- новую картинку `иконка2.png` использовать только для Launcher Icon;
- adaptive icon background оставить светлым;
- текущие `Monochrome Icon` и `Notification Small Icon` не менять.

Что сделано:
- Источник: `C:\Users\railt\Downloads\иконка2.png`, размер `512x512`.
- Сгенерированы launcher PNG с небольшим внутренним полем, чтобы знак не резался круглыми/скругленными масками лаунчеров.
- Заменены только Android launcher assets:
  - `mobile-app/android/app/src/main/res/mipmap-mdpi/ic_launcher.png` (`48x48`)
  - `mobile-app/android/app/src/main/res/mipmap-hdpi/ic_launcher.png` (`72x72`)
  - `mobile-app/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png` (`96x96`)
  - `mobile-app/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` (`144x144`)
  - `mobile-app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png` (`192x192`)
  - `mobile-app/android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png` (`108x108`)
  - `mobile-app/android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png` (`162x162`)
  - `mobile-app/android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground.png` (`216x216`)
  - `mobile-app/android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png` (`324x324`)
  - `mobile-app/android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png` (`432x432`)

Не менялось:
- `mobile-app/android/app/src/main/res/drawable/ic_notification_g.xml`
- `mobile-app/android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`
- `mobile-app/android/app/src/main/res/values/colors.xml`

Проверка:
- `cd /opt/grani/mobile-app/android && ./gradlew :app:processReleaseResources --offline --no-daemon`: `BUILD SUCCESSFUL`.
- APK не собирался.

## Аудит 2026-05-18: модуль устройств, "Мои устройства", лимит устройств

Запрос пользователя: проверить, почему модуль устройств выглядит нерабочим: устройства как будто не добавляются, а попап лимита устройств может не появляться.

Что проверено:
- Backend:
  - `backend/application/services/device_manager.py`
  - `backend/infrastructure/repositories/device_repository.py`
  - `backend/api/vpn.py`
  - `backend/api/simple_vpn.py`
  - таблица `devices`
- Mobile:
  - `mobile-app/lib/services/vpn_service.dart`
  - `mobile-app/lib/simple_vpn/simple_vpn_controller.dart`
  - `mobile-app/lib/screens/devices_screen.dart`
  - `mobile-app/lib/core/session/device_limit_flow.dart`
  - `mobile-app/lib/widgets/pending_device_limit_listener.dart`
  - `mobile-app/lib/main.dart`

Наблюдения из prod-логов:
- 2026-05-18 в логах есть успешные вызовы:
  - `POST /api/vpn/device/register status=200`
  - `GET /api/vpn/devices status=200`
  - `GET /api/simple-vpn/config status=200`
  - `POST /api/simple-vpn/session/start status=200`
- То есть регистрация устройства не полностью мертвая: endpoint вызывается и отвечает.

Наблюдения из БД:
- В `devices` сейчас 19 строк.
- У user_id=1 есть активное устройство `79cca8e5-c33f-4d72-9510-179e149f8fd7`, сервер `3`, `vpn_protocol=graniwg`, `is_active=true`.
- У многих тестовых строк одинаковый fingerprint `15764cadd6...`.
- Это означает: при тестах на одном и том же телефоне/после переустановки система может намеренно переиспользовать/разрешать тот же логический девайс, а не добавлять новую карточку.

Главные проблемы:
1. `PendingDeviceLimitListener` написан, но не подключен в `main.dart`.
   - Файл `mobile-app/lib/widgets/pending_device_limit_listener.dart` умеет слушать `AuthService.setPendingDeviceLimit()` и показывать модалку.
   - Но глобальный `MaterialApp.builder` в `mobile-app/lib/main.dart` оборачивает app только в `_AppLifecycleHandler`, `_AuthRedirectListener`, `_PreloadVpnWidget`.
   - Поэтому если лимит пойман фоновой регистрацией после логина, pending выставляется, но попап никто не открывает.
   - Это прямой баг для сценария "после входа лимит устройств".

2. `backend/api/simple_vpn.py` обходит canonical `DeviceManager`.
   - `_simple_device()` сам создает/активирует `Device`, если строки нет.
   - Этот путь не использует `DeviceManager.register_device()`, не проверяет `_DEVICE_LIMIT`, не использует нормальную обработку fingerprint/name/platform и не инвалидирует cache списка устройств.
   - Сейчас mobile обычно перед `/simple-vpn/config` вызывает `/vpn/device/register`, поэтому на штатном пути это частично компенсируется.
   - Но архитектурно это слабое место: GRANIwg config/session не должны уметь создавать устройство в обход лимита.

3. Регистрация на клиенте местами мягко пропускает сетевые ошибки.
   - В `VpnService._registerDeviceIfNeeded()` при timeout/connectionError есть лог "Продолжаем работу, но устройство может быть не зарегистрировано".
   - Это сделано ради доступности VPN, но для production device-limit логики такой soft-fail может скрывать проблему регистрации.
   - Для текущего `SimpleVpnController` регистрация вызывается перед чтением cache, но если registration не упала лимитом, подключение может пойти дальше.

4. Лимит backend и лимит UI могут расходиться.
   - Backend `DeviceManager` использует hardcoded `_DEVICE_LIMIT = 5`.
   - UI берет `AuthService.maxDevices`.
   - Если тарифные лимиты отличаются от 5, поведение попапа и backend-ошибки может быть несогласованным.

Предлагаемый порядок исправлений:
1. Подключить `PendingDeviceLimitListener` в `main.dart` вокруг текущего app child, чтобы pending лимит после фоновой регистрации действительно показывался.
2. Закрыть обход в `simple_vpn.py`: `/simple-vpn/config`, `/simple-vpn/session/verify` должны работать только с уже зарегистрированным устройством или идти через `DeviceManager`.
3. Сделать device registration обязательной для GRANIwg connect, кроме явно диагностического fallback. При ошибке регистрации показывать понятную ошибку, а не тихо продолжать.
4. Свести лимит устройств к одному источнику: тариф/план на backend, а UI только отображает backend limit.
5. Добавить тесты:
   - register same device twice -> одна логическая карточка;
   - register sixth unique device -> `DEVICE_LIMIT_EXCEEDED`;
   - pending limit after login -> modal appears;
   - `/simple-vpn/config` без зарегистрированного device_id не создает обходную строку.

APK не собирался.

## Реализация 2026-05-18: device limit popup и запрет обхода регистрации в simple-vpn

Сделано:
- `mobile-app/lib/main.dart`
  - Добавлен импорт `widgets/pending_device_limit_listener.dart`.
  - Корневой `MaterialApp.builder` теперь оборачивает приложение в `PendingDeviceLimitListener`.
  - Теперь `AuthService.setPendingDeviceLimit()` после фоновой регистрации действительно должен открывать модалку лимита устройств.
- `backend/api/simple_vpn.py`
  - `_simple_device()` больше не создает `Device` напрямую.
  - Если `device_id` не передан, возвращается `400` с code `DEVICE_REQUIRED`.
  - Если `device_id` передан, но устройство не зарегистрировано для пользователя, возвращается `409` с code `DEVICE_NOT_REGISTERED`.
  - Это закрывает обход `DeviceManager.register_device()` и лимита устройств через `/simple-vpn/config` / verify.
  - После успешного GRANIwg config/provision invalidate cache `cache:devices:{user_id}`.
  - `/simple-vpn/session/stop` теперь переводит устройство в inactive:
    - `is_active=false`
    - `current_server_id=null`
    - `ip_address=null`
    - `vpn_protocol=null`
    - также инвалидирует `cache:devices:{user_id}`.

Деплой/проверка:
- `python3 -m py_compile backend/api/simple_vpn.py`: OK.
- `/opt/flutter/bin/dart format lib/main.dart`: выполнено.
- `/opt/flutter/bin/dart analyze lib/main.dart`: blocking errors нет; остались старые warning/info по неиспользуемым методам/const в `main.dart`.
- Перезапущен только `granivpn_api`.
- `granivpn_api` поднялся healthy, `/health` отвечает 200.
- APK не собирался.

Ожидаемое поведение после следующей APK-сборки:
- При лимите устройств после логина pending modal теперь должен появляться.
- Если регистрация устройства не прошла, `/simple-vpn/config` больше не создаст обходную запись `Device`; подключение должно остановиться ошибкой регистрации/устройства.
- После отключения simple-vpn список "Мои устройства" должен быстрее показывать устройство inactive, без ожидания TTL кэша.

## Исправление 2026-05-19: локализация динамических текстов подключения

Проблема:
- В English locale экран подключения показывал английские основные статусы (`Connecting...`), но новые динамические тексты progress/badge оставались русскими:
  - `Первичная настройка`
  - `Соединение может занять немного больше времени из-за сети.`

Сделано:
- Реализация приведена к существующему паттерну проекта: строки берутся через `AppLocalizations`/ARB, а не через локальный словарь в экране.
- `mobile-app/lib/screens/main/vpn_shell_ui_helpers.dart`
  - Расширен общий helper `VpnShellUiHelpers`.
  - Добавлены методы:
    - `simpleProgressMessage(raw, l10n)`
    - `simpleConnectionBadge(raw, l10n)`
  - Они мапят сырые progress/badge строки `SimpleVpnController` на уже существующие l10n-ключи:
    - `vpnProgress*`
    - `vpnBadgeFastReconnect`
    - `vpnBadgeFirstSetup`
    - `vpnSlowNetworkWarm/Cold`
    - `vpnRetryRouteWarm`
    - `vpnOptimizeRoute`
    - `vpnConnectPatienceWarm/Cold`
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`
  - Убран экранный словарь переводов.
  - Экран теперь вызывает `VpnShellUiHelpers.simpleProgressMessage(...)` и `simpleConnectionBadge(...)`.
  - Так английская версия получает тексты из `app_en.arb`, русская — из `app_ru.arb`, как остальные экраны приложения.

Проверка:
- `/opt/flutter/bin/dart format lib/screens/main/clean_amnezia_home_screen.dart`
- `/opt/flutter/bin/dart format lib/screens/main/vpn_shell_ui_helpers.dart`
- `/opt/flutter/bin/dart analyze lib/screens/main/clean_amnezia_home_screen.dart lib/screens/main/vpn_shell_ui_helpers.dart`: `No issues found`.
- APK не собирался в этом шаге.

## Исправление 2026-05-19: предупреждение при смене сервера/протокола во время VPN

Проблема:
- На экране `CleanAmneziaHomeScreen` при попытке сменить сервер или протокол во время активного VPN показывался ручной дефолтный `SnackBar`:
  - темный/синий фон, не по стилю проекта;
  - текст был захардкожен на русском: `Отключите VPN, чтобы сменить сервер или протокол`.

Как принято в проекте:
- `mobile-app/lib/widgets/snackbar_utils.dart`
  - `showErrorSnackBar(...)`: розовый фон `GraniTheme.errorBackground`, красный текст `GraniTheme.errorText`, Montserrat, floating.
  - Используется для ошибок/предупреждений.
- Тексты UI лежат в `app_en.arb/app_ru.arb` и используются через `context.l10n`.

Сделано:
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`
  - `_showLockedSelectorMessage()` теперь вызывает:
    - `showErrorSnackBar(context, context.l10n.homeSelectorLocked)`
  - Убран ручной `ScaffoldMessenger.of(context).showSnackBar(const SnackBar(...))`.
- `mobile-app/lib/l10n/app_en.arb`
  - Добавлен ключ:
    - `homeSelectorLocked`: `Disconnect VPN to change the server or protocol`
- `mobile-app/lib/l10n/app_ru.arb`
  - Добавлен ключ:
    - `homeSelectorLocked`: `Отключите VPN, чтобы сменить сервер или протокол`
- Выполнен `flutter gen-l10n`, обновлены generated файлы:
  - `app_localizations.dart`
  - `app_localizations_en.dart`
  - `app_localizations_ru.dart`

Проверка:
- `/opt/flutter/bin/flutter gen-l10n`: OK.
- `/opt/flutter/bin/dart format ...`: OK.
- `/opt/flutter/bin/dart analyze lib/screens/main/clean_amnezia_home_screen.dart lib/l10n/app_localizations.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_ru.dart`: `No issues found`.
- APK не собирался в этом шаге.

## Реализация 2026-05-19: отмена подключения на новой GRANIwg-кнопке

Требование:
- Во время `connecting` пользователь должен иметь возможность отменить подключение, как на старой кнопке.
- Отмена не должна выкидывать уже полезно подготовленные данные: device registration, config cache, prepared peer.
- При повторном нажатии подключение должно идти быстрее за счет уже сохраненного cache.

Архитектура решения:
- `mobile-app/lib/simple_vpn/simple_vpn_controller.dart`
  - Добавлен внутренний `_SimpleVpnConnectCancelled`.
  - Добавлены поля текущей попытки:
    - `_connectAttemptId`
    - `_connectCancelRequested`
    - `_activeConnectSessionId`
    - `_activeConnectDeviceId`
  - `toggle()` теперь при `SimpleVpnState.connecting` вызывает `cancelConnect(...)`.
  - Добавлен `cancelConnect({source})`:
    - ставит `_connectCancelRequested=true`;
    - показывает progress `Отменяем подключение...`;
    - вызывает `NativeVpnService.disconnectAmneziaWg(reason=connect_cancelled)`;
    - если session уже создана, вызывает `/simple-vpn/session/stop` с `reason=user_cancel`.
  - В `connect()` после ключевых async-этапов добавлена проверка `_throwIfConnectCancelled(attemptId)`:
    - после `loadOptions`;
    - после регистрации/resolve device;
    - после получения/кэширования config;
    - после session start;
    - после preconnect disconnect;
    - после native start;
    - после fallback config refresh/native retry;
    - перед финальным success.
  - При cancel:
    - session закрывается как `user_cancel`;
    - native tunnel гасится как `connect_cancelled`;
    - active session id очищается;
    - UI возвращается в `disconnected`;
    - логируется `connect_cancelled`.
  - Уже полученный config сохраняется в cache до выхода по cancel.

UI:
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`
  - При `connecting` большая кнопка теперь активна и вызывает `_controller.cancelConnect()`.
  - Текст внутри кнопки при `connecting`: `context.l10n.btnVpnCancel`.
- `mobile-app/lib/l10n/app_en.arb`
  - Добавлен `btnVpnCancel`: `cancel`.
  - Добавлен `vpnProgressConnectCancelling`: `Cancelling connection...`.
- `mobile-app/lib/l10n/app_ru.arb`
  - Добавлен `btnVpnCancel`: `отменить`.
  - Добавлен `vpnProgressConnectCancelling`: `Отменяем подключение...`.
- `mobile-app/lib/screens/main/vpn_shell_ui_helpers.dart`
  - `simpleProgressMessage(...)` теперь переводит `Отменяем подключение...` через `l10n.vpnProgressConnectCancelling`.

Проверка:
- `/opt/flutter/bin/flutter gen-l10n`: OK.
- `/opt/flutter/bin/dart format ...`: OK.
- `/opt/flutter/bin/dart analyze lib/simple_vpn/simple_vpn_controller.dart lib/screens/main/clean_amnezia_home_screen.dart lib/screens/main/vpn_shell_ui_helpers.dart lib/l10n/app_localizations.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_ru.dart`: `No issues found`.
- APK не собирался в этом шаге.

## Обновление 2026-05-18: Quick Tile без открытия приложения + правка стилистики badge

Новый тест пользователя:
- Туннелирование сайтов работает ок.
- Быстрая кнопка не ок: при закрытом/свернутом приложении открывает приложение.
- Новый badge/progress-текст у кнопки визуально выбивался: синее выделение не в стиле остальных текстов.

Что изменено:
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/QuickTileService.kt`
  - Tile больше не обязан открывать Flutter `MainActivity` для штатного toggle.
  - Если VPN уже поднят, tile отключает native dataplane в фоне:
    - `SimpleAmneziaWgRunner.disconnect()` для GRANIwg.
    - `GraniVpnService.stopService()` для старого service path.
  - Если VPN выключен, tile берет последний сохраненный verified config через `VpnPlugin.loadLastConfig(...)`.
  - Для GRANIwg запускает `SimpleAmneziaWgRunner.connect(...)` напрямую из native background thread.
  - Для старого protocol path запускает `GraniVpnService.startService(..., source="quick_tile_cached")`.
  - Если cached config отсутствует, tile показывает подсказку и только тогда открывает приложение как fallback.
  - Если Android VPN permission еще не выдан, tile открывает прозрачный `QuickTileToggleActivity` только для системного permission flow.
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/QuickTileToggleActivity.kt`
  - После выдачи системного VPN permission стартует cached config в фоне, а не основной экран.
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnPlugin.kt`
  - После успешного `connectAmneziaWg` теперь сохраняется последний GRANIwg config в native prefs:
    - `saveLastConfig(ctx, config, "graniwg", 0)`
  - Это нужно, чтобы Quick Tile мог подключать GRANIwg без поднятия Flutter UI после первого успешного подключения из приложения.
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`
  - Badge `Быстрое восстановление` / `Первичная настройка` больше не рисуется синей плашкой.
  - Теперь это тонкий текст в стиле остальных подписей: Montserrat, легкий вес, темный цвет с прозрачностью.

Важное ограничение текущей production-практичной версии:
- Первое подключение после установки/очистки данных все равно должно пройти через приложение, чтобы получить backend config, системное VPN permission и сохранить verified cached config.
- После этого Quick Tile работает как дублер основной кнопки по dataplane: включает/выключает VPN без открытия приложения.
- Полная версия с backend session start/stop из полностью закрытого приложения потребует отдельного secure native auth bridge или headless Flutter path, потому что auth token живет в FlutterSecureStorage.

Проверка:
- `dart format mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`
- `dart analyze mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`: `No issues found`.
- `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin`: `BUILD SUCCESSFUL`.
- APK после этой правки не собирался по ограничению пользователя.

Тест после будущей APK-сборки:
1. Установить APK, открыть приложение, один раз подключиться основной кнопкой к любому рабочему серверу.
2. Убедиться, что VPN работает, затем отключить.
3. Свернуть/закрыть приложение.
4. Нажать Quick Tile: приложение не должно открываться; VPN должен подняться по cached GRANIwg config.
5. Открыть YouTube/Chrome/2ip.ru и проверить интернет.
6. Нажать Quick Tile еще раз: приложение не должно открываться; VPN должен отключиться.
7. Если после чистой установки нажать tile до первого успешного подключения, допустимый fallback: приложение откроется, потому что cached config еще отсутствует.

## Обновление 2026-05-18: аудит и восстановление уведомлений

Запрос пользователя:
- Проверить, почему "вроде вообще ни одного уведомления нет".
- Выполнить исправления.

Аудит показал 3 основные проблемы:
1. В `AndroidManifest.xml` отсутствовал `android.permission.POST_NOTIFICATIONS`.
   - При `targetSdk=36` это блокирует обычные push/local notifications на Android 13+.
2. Старый `GraniVpnService` умеет foreground notification (`grani_vpn_channel`, `GRANI`, `VPN подключён`), но текущий рабочий GRANIwg path идет через `SimpleAmneziaWgRunner -> GoBackend$VpnService`.
   - Embedded `GoBackend$VpnService` из AmneziaWG не создает наше foreground notification.
   - Поэтому при подключении через GRANIwg/Quick Tile в шторке могло не быть VPN-уведомления.
3. Серверный Celery worker был фактически остановлен:
   - `docker inspect granivpn_celery`: `status=exited`, `exit=1`, старая ошибка `no space left on device` в Docker overlay.
   - Redis-очереди до поднятия worker:
     - `default=499`
     - `vpn=124`
     - `monitoring≈36317`
   - Beat ставил задачи, но worker их не разгребал, поэтому scheduled уведомления trial/subscription могли не уходить.

Что сделано:
- Сервер:
  - Выполнен `docker start granivpn_celery`.
  - Worker поднялся и начал обрабатывать задачи.
  - После запуска:
    - `default=0`
    - `vpn=0`
    - `monitoring≈35697` (это хвост server health/load/observability, не критичный для push напрямую).
- Android:
  - `mobile-app/android/app/src/main/AndroidManifest.xml`
    - Добавлен `android.permission.POST_NOTIFICATIONS`.
    - Добавлен service `.GraniAwgNotificationService` с `foregroundServiceType="specialUse"` и `special_use_fgs_subtype="vpn"`.
  - `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/GraniAwgNotificationService.kt`
    - Новый тонкий foreground-service только для уведомления GRANIwg.
    - Создает канал `grani_vpn_channel` / `GRANI VPN`.
    - Показывает ongoing notification: `GRANI` / `VPN подключён`.
    - Использует `ic_notification_g`.
  - `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/SimpleAmneziaWgRunner.kt`
    - После успешного `GoBackend.setState(..., UP, ...)` запускает `GraniAwgNotificationService.start(...)`.
    - На `disconnect()` останавливает `GraniAwgNotificationService`.

Проверка:
- `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin`: `BUILD SUCCESSFUL`.
- APK после этой правки не собирался по ограничению пользователя.

Тест после будущей APK-сборки:
1. Установить APK.
2. После входа/логина Android 13+ должен запросить разрешение на уведомления.
3. Разрешить уведомления.
4. Подключиться основной кнопкой к GRANIwg.
5. Проверить шторку: должно быть ongoing-уведомление `GRANI` / `VPN подключён`.
6. Отключиться: уведомление должно исчезнуть.
7. Подключиться через Quick Tile при закрытом приложении: приложение не должно открываться, уведомление должно появиться.
8. Отключиться через Quick Tile: уведомление должно исчезнуть.
9. Для push: отправить/сымитировать backend-событие `subscription_activated` или `payment_completed`; проверить системный push, foreground banner и журнал уведомлений.

Остаточные риски:
- Если пользователь на Android 13+ запретит notification permission, обычные push/local уведомления не появятся; foreground-service notification тоже может быть скрыт из шторки системой, хотя VPN будет работать.
- Monitoring queue еще имеет большой хвост. Это не блокирует push напрямую, но стоит отдельно почистить/дедуплицировать устаревшие monitoring-задачи или временно остановить beat для health/load, если очередь снова начнет разрастаться.

## APK 2026-05-18: domain split + quick tile + UX button

По явной команде пользователя собрана release APK:
- build command: `cd /opt/grani && ./build_release_apk.sh`
- output: `/opt/grani/granivpn-release-arm64.apk`
- published:
  - `https://api.granilink.com/downloads/grani-vpn-20260518-domain-tile-ux.apk`
  - `https://api.granilink.com/downloads/app-release.apk?v=20260518-domain-tile-ux`
- size: `87214608` bytes
- SHA256: `319839c69ad92345fd883922c20dda85f7968e67b859445c5e7b70a821f1b21d`
- URL check: оба download URL вернули `HTTP/2 200`.

Что входит в сборку:
- GRANIwg domain split: DNS->IPv4 cache, `AllowedIPs` complement, fallback без потери интернета.
- Quick Settings Tile как тонкий слой: tile открывает app с `QUICK_TILE_ACTION=toggle`, Flutter вызывает тот же `SimpleVpnController.toggle(source=quick_tile)`.
- UX новой кнопки: progress-тексты, long-connect сообщения, badge `Быстрое восстановление`/`Первичная настройка`.

Тест domain split:
1. Установить APK.
2. В Android/Chrome выключить Android Private DNS и Chrome Secure DNS для чистого теста.
3. В split tunnel domains добавить `2ip.ru`.
4. Приложения в app split не отмечать.
5. Подключиться к HU GRANIwg.
6. В logcat ожидать:
   - `split tunnel domains: resolve ...`
   - `split tunnel domains: applied domains=...`
7. Открыть `2ip.ru` в Chrome: сайт должен показывать direct-провайдера/не Венгрию.
8. Открыть другой IP-check сайт, не добавленный в domains: он должен идти через VPN и показывать Венгрию.
9. Если `2ip.ru` все равно показывает Венгрию, собрать строки logcat `split tunnel domains`; вероятные причины: Chrome DoH/Private DNS, CDN-IP отличается от системного resolve на момент connect.

Тест quick tile:
1. После установки открыть app, авторизоваться, убедиться что подписка/trial активны.
2. Добавить GRANI quick tile в шторку Android.
3. VPN off, app открыт: нажать tile. Ожидание: app/главный экран вызывает connect, в logcat/source backend будет `source=quick_tile`, session id не null.
4. VPN on: нажать tile. Ожидание: disconnect через `SimpleVpnController`, `/simple-vpn/session/stop`, source=`quick_tile`.
5. App в фоне/закрыт, VPN off: нажать tile. Ожидание: app открывается на `/main` и выполняет тот же connect.
6. Нет системного VPN permission: нажать tile. Ожидание: Android permission flow, после разрешения обычный connect.
7. Нет подписки/trial и VPN off: tile не стартует VPN, открывает paywall/subscription.
8. Проверить двойной быстрый тап: второй тап игнорируется native debounce/Flutter `isBusy`.
9. Повторный connect после успешного первого: ожидать cache hit и badge `Быстрое восстановление`.

Текущий статус реализации:
- Для GRANIwg domain split уже есть первый production-слой: exact/root + `www.`, DNS->IPv4 cache, `AllowedIPs` complement, fallback без потери интернета.
- Это должно решить кейс `2ip.ru` при условии, что Chrome/Android используют системный DNS или совпадающий IP.
- Полностью динамический wildcard/subdomain/CDN слой остается следующим этапом: нужен DNS observer/refresh или domain-aware engine, чтобы ловить новые IP после старта туннеля.

## Обновление 2026-05-18: Quick Settings Tile как дублер основной кнопки

Решение по смене сети: пока не трогаем. Текущий AmneziaWG/WireGuard roaming работает, агрессивный reconnect не нужен.

Задача: реанимировать быструю кнопку Android так, чтобы она была тонким слоем и дублером основной кнопки подключения, а не отдельным VPN-механизмом.

Проблема старого состояния:
- `QuickTileService` напрямую стартовал `GraniVpnService.startService(...)` из `last_vpn_config`.
- Это обходило текущий GRANIwg путь `SimpleVpnController -> /simple-vpn/session/start -> connectAmneziaWg -> SimpleAmneziaWgRunner`.
- Риски старого пути: `session=null`, нет backend session, нет корректной analytics/verify связки, не гарантирован cache contract `(device_id, protocol, server_id)`, domain/app split мог не совпадать с основной кнопкой.

Что сделано:
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/QuickTileService.kt`
  - Tile больше не стартует VPN напрямую из `last_vpn_config`.
  - Нажатие tile ставит pending-состояние и открывает `MainActivity` с extras:
    - `INITIAL_ROUTE=/main`
    - `QUICK_TILE_ACTION=toggle`
  - Если подписки/триала нет и VPN сейчас выключен, как раньше открывается paywall/подписка.
  - Если VPN уже включен, tile разрешает отключение даже при истекшей подписке.
  - Состояние tile теперь active, если работает `GraniVpnService.isVpnRunning()` или `SimpleAmneziaWgRunner.isUp()`.
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/MainActivity.kt`
  - Добавлен `onNewIntent(...)` с `setIntent(intent)`, чтобы warm-start tile action был виден Flutter.
- `mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnPlugin.kt`
  - Добавлен MethodChannel method `takeQuickTileAction`.
  - Метод возвращает одноразовый action из текущего Activity intent и сразу очищает extra, чтобы toggle не повторялся.
- `mobile-app/lib/services/native_vpn_service.dart`
  - Добавлен `NativeVpnService.takeQuickTileAction()`.
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`
  - На старте экрана и при resume забирает pending quick tile action.
  - Для `toggle` вызывает `_controller.syncNativeState()`, затем `_controller.toggle(source: 'quick_tile')`.
  - После выполнения просит native обновить tile: `requestQuickTileRefresh`.
- `mobile-app/lib/simple_vpn/simple_vpn_controller.dart`
  - `toggle/connect/disconnect` получили параметр `source`, по умолчанию `simple_vpn`.
  - Quick tile передает `source=quick_tile`.
  - Native start получает тот же `source`.
  - Backend logs/analytics details получают `source`.
  - Disconnect через tile закрывает session тем же контроллером и reason=`user`, source=`quick_tile`.

Итоговая архитектура:
- Quick Tile = UI/intent/status only.
- Flutter `SimpleVpnController` = единственная бизнес-логика подключения.
- Native `SimpleAmneziaWgRunner` = фактический start/stop GRANIwg.
- Следовательно, tile использует тот же cache, session start, selected server, split apps/domains, verify и analytics, что и основная кнопка.

Проверка:
- `dart format` для измененных Dart-файлов выполнен.
- `dart analyze mobile-app/lib/simple_vpn/simple_vpn_controller.dart mobile-app/lib/services/native_vpn_service.dart mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`: ошибок нет; остались только старые info-подсказки `use_super_parameters` в `native_vpn_service.dart`.
- `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin`: `BUILD SUCCESSFUL`.
- APK не собирался.

Тест после будущей APK-сборки:
1. App открыт, VPN off: нажать tile -> должен подключиться как основная кнопка; в логах `source=quick_tile`, session id не null.
2. App закрыт/в фоне, VPN off: нажать tile -> app откроется на `/main`, выполнит connect через `SimpleVpnController`.
3. VPN on: нажать tile -> отключение через тот же controller, backend `/session/stop`, source=`quick_tile`.
4. Нет системного VPN permission: tile открывает app/permission flow, дальше основной путь.
5. Нет подписки/триала и VPN off: tile не стартует VPN, открывает paywall.
6. Проверить cache hit на повторном подключении и domain split `2ip.ru`: quick tile должен вести себя как основная кнопка.

## Обновление 2026-05-18: восстановление UX старой кнопки подключения

Пользователь описал старую кнопку: 5 состояний (`off/connecting/disconnecting/on/error`), человеческие заголовки/подзаголовки, динамические progress-тексты при подключении, long-connect сообщения, бейджи `Быстрое восстановление` / `Первичная настройка`, trial-тексты и подсказки.

Цель текущего этапа: вернуть живую UX-обвязку вокруг новой надежной GRANIwg-кнопки, не ломая механику подключения.

Что сделано:
- `mobile-app/lib/simple_vpn/simple_vpn_controller.dart`
  - Добавлены UI-поля состояния:
    - `connectionProgressText`
    - `connectionModeBadge`
    - `connectionProgressPercent`
  - Добавлен timer long-connect: каждые 12 секунд при долгом `connecting` подставляет спокойные сообщения вроде:
    - `Соединение может занять немного больше времени из-за сети.`
    - `Пробуем другой маршрут подключения...`
    - `Восстановление связи занимает дольше обычного — подождите, подключение продолжается.`
    - `Первичная настройка на медленной сети может занять до минуты — подождите, это нормально.`
  - Реальные этапы подключения теперь обновляют UI:
    - `Проверяем доступ...`
    - `Выбираем оптимальный сервер...`
    - `Регистрируем устройство...`
    - `Готовим защищенный профиль...`
    - `Восстанавливаем защищенный профиль...`
    - `Проверяем параметры подключения...`
    - `Создаем защищенный туннель...`
    - `Запускаем защищенный канал...`
    - `Проверяем защищенный трафик...`
    - `Соединение установлено`
  - При cache hit выставляется badge `Быстрое восстановление`.
  - При cache miss/config fetch выставляется badge `Первичная настройка`.
  - При disconnect выставляется `Завершаем защищённое соединение`.
  - Timer и progress корректно очищаются при success/error/disconnect/dispose.
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`
  - `connecting` subtitle теперь берет `controller.connectionProgressText`.
  - `disconnecting` subtitle берет progress text или fallback `Завершаем защищённое соединение`.
  - Добавлен компактный badge под заголовком во время connecting.
  - В `ConnectionBlock` передается `connectionProgressPercent`.

Что сознательно не сделано в этом этапе:
- Не включали отмену по нажатию во время `connecting`, потому что текущий connect включает permission flow/backend/native start, и преждевременная отмена требует отдельной безопасной cancel-механики.
- Не возвращали speed block в minimal mode, чтобы не раздвигать текущий макет. Это можно вернуть отдельным аккуратным этапом после проверки на устройстве.
- Trial-specific отдельные тексты пока не трогались: текущий активный экран `CleanAmneziaHomeScreen`; trial UX лучше восстановить отдельным проходом после проверки основной кнопки.

Проверка:
- `dart format mobile-app/lib/simple_vpn/simple_vpn_controller.dart mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`
- `dart analyze mobile-app/lib/simple_vpn/simple_vpn_controller.dart mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`: `No issues found`.
- `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin`: `BUILD SUCCESSFUL`.
- APK не собирался.

## Обновление 2026-05-25: третий GRANIwg сервер IE-DUB-01 добавлен и подготовлен

Запрос пользователя:
- Добавить в работу полный третий сервер.
- Подготовить и подключить его с нормальной безопасностью.

Новый сервер:
- Name: `IE-DUB-01`
- IP: `194.4.51.125`
- Geo: Ireland / Dublin (`Ирландия`, `Дублин`)
- Provider/org по ipinfo: WorkTitans B.V.
- OS: Ubuntu 20.04.6 LTS

Что сделано по доступу и безопасности:
- Первичный парольный доступ использован только для установки SSH key.
- На сервер добавлен публичный ключ `/opt/grani/.ssh/grani_vpn_key.pub`.
- Доступ по ключу с основного GRANI-сервера проверен.
- SSH password login отключен:
  - `PasswordAuthentication no`
  - `PermitRootLogin prohibit-password`
  - `PubkeyAuthentication yes`
  - `KbdInteractiveAuthentication no`
  - `MaxAuthTries 3`
- Важный нюанс: `50-cloud-init.conf` переопределял `PasswordAuthentication yes`; он изменен на `PasswordAuthentication no`.
- `fail2ban` установлен, включен и активен.
- Во время первичной настройки fail2ban забанил IP основного GRANI-сервера после нескольких ошибочных password-попыток; бан был снят, дальнейшая работа шла только по ключу.

Что сделано по VPN-ноду:
- Установлены `wireguard`, `wireguard-tools`, `fail2ban`, `unattended-upgrades`.
- Включен forwarding:
  - `net.ipv4.ip_forward=1`
  - `net.ipv6.conf.all.forwarding=1`
- Создан `/etc/wireguard/wg0.conf`:
  - Address `10.0.0.1/24`
  - ListenPort `51820`
  - MTU `1420`
  - NAT через `ens3`
  - `SaveConfig=false`
- `wg-quick@wg0` включен в автозапуск и активен.
- UDP `51820` слушает.
- Smoke test add/remove peer через backend `WireGuardManager` прошел:
  - temp peer был добавлен на `10.0.0.2`, найден в config, затем удален и config очищен.

База данных:
- Добавлен server id `4`:
  - `name=IE-DUB-01`
  - `country=Ирландия`
  - `city=Дублин`
  - `ip_address=194.4.51.125`
  - `is_active=true`
  - `is_local=false`
  - `ssh_user=root`
  - `ssh_key_content` заполнен ключом управления
  - `ssh_password=NULL`
  - `wireguard_port=51820`
  - `wireguard_public_key` заполнен с ноды
  - `graniwg_enabled=true`
  - `graniwg_obfuscation_type=amneziawg`
  - `graniwg_obfuscation_key={"Jc":4,"Jmin":5,"Jmax":60}`
  - `supported_protocols=["graniwg"]`

Health-check fix:
- До фикса UK и IE могли показывать `health_status=error`, потому что ICMP/ping закрыт или не отвечает, хотя SSH/WireGuard работают.
- Исправлен `backend/services/tasks/server_monitoring_tasks.py`:
  - если ping недоступен, но `graniwg_enabled=true`, health fallback проверяет SSH и `wg show` через `RemoteVPNManager`;
  - источник latency/status становится `wireguard_ssh`;
  - рабочие GRANIwg-ноды без ICMP больше не помечаются error.
- Перезапущены `granivpn_celery` и `granivpn_beat`.
- Ручной `server.check_server_health` после фикса:
  - HU-BUD-01 healthy via `icmp`, ping около 160 ms;
  - UK-LON-01 healthy via `wireguard_ssh`;
  - IE-DUB-01 healthy via `wireguard_ssh`.

Текущий статус после работ:
- `granivpn_api` healthy.
- `granivpn_celery` и `granivpn_beat` запущены после рестарта.
- DB servers:
  - HU-BUD-01 healthy, GRANIwg enabled.
  - UK-LON-01 healthy, GRANIwg enabled.
  - IE-DUB-01 healthy, GRANIwg enabled.

Следующий тест пользователем:
1. Открыть приложение.
2. Обновить список серверов/перезайти на экран, если список уже был загружен.
3. Выбрать `Дублин, Ирландия` / `IE-DUB-01`.
4. Подключиться GRANIwg.
5. Проверить YouTube/2ip/speedtest.

Важно:
- Новая APK не собиралась и не нужна для появления сервера, если текущая сборка берет список серверов с `/api/simple-vpn/servers`.
- Если приложение держит список в памяти, достаточно перезапустить приложение.

## Обновление 2026-05-26 08:55 MSK — статус перед финальными тестами приложения

Цель дня:
- провести последние тесты приложения перед запуском;
- работать по единому контексту `/opt/grani/docs/VPN_WORK_CONTEXT.md`;
- код без отдельного решения не менять.

Текущий runtime-статус инфраструктуры:
- `granivpn_api` up/healthy;
- `granivpn_nginx`, `granivpn_postgres`, `granivpn_redis`, `granivpn_celery`, `granivpn_beat`, `granivpn_admin` запущены;
- контейнеры работают 13-14 часов после последнего рестарта.

Текущий статус серверов в DB:
- `HU-BUD-01` id=1, `45.12.132.94`, active, health `healthy`, `graniwg_enabled=true`;
- `UK-LON-01` id=3, `45.140.167.123`, active, health `healthy`, `graniwg_enabled=true`;
- `IE-DUB-01` id=4, `194.4.51.125`, active, health `healthy`, `graniwg_enabled=true`.

Последние успешные backend-верификации GRANIwg 2026-05-25:
- HU id=1: `session/verify verified=True`, vpn_ip `10.0.0.11`;
- UK id=3: `session/verify verified=True`, vpn_ip `10.0.0.4`;
- IE id=4: `session/verify verified=True`, vpn_ip `10.0.0.2`;
- IE проверялся несколько раз, включая быстрый verify с handshake_age 5-21 сек.

APK/download статус:
- публичный стандартный download URL отвечает `HTTP/2 200`:
  - `https://api.granilink.com/downloads/app-release.apk`;
- текущий опубликованный `app-release.apk` имеет `last-modified: Tue, 19 May 2026 12:24:11 GMT`, размер `87485504` bytes;
- по имени последняя заметная сборка: `grani-vpn-20260519-full-cycle-v21.apk`.

Важный блокер перед тестами:
- тестовый пользователь `railcuber@gmail.com` / user_id=23 сейчас без активного доступа;
- последние подписки user_id=23 в DB имеют status `expired`;
- в логах за 2026-05-25 после истечения доступа видны ожидаемые `402 Нет активного VPN-доступа` на `/api/simple-vpn/session/verify`, `/servers`, `/protocols`, `/session/start`;
- перед финальными тестами нужно либо оформить/активировать тестовую подписку, либо вручную выдать временный доступ.

Что считать рабочей базой на данный момент:
- основной протокол для финального запуска: GRANIwg / AmneziaWG path;
- Xray/VLESS/VMESS больше не является целевым путем запуска;
- три рабочих backend-ноды GRANIwg уже есть: HU, UK, IE;
- сервер IE добавлен без новой APK, потому что список серверов берется через `/api/simple-vpn/servers`.

Рекомендуемый порядок финальных тестов:
1. Сначала восстановить активный VPN-доступ тестовому аккаунту.
2. Перезапустить приложение, чтобы обновить bootstrap/servers/protocols.
3. Проверить основной connect/disconnect на IE-DUB-01.
4. Проверить connect/disconnect на UK-LON-01.
5. Проверить connect/disconnect на HU-BUD-01.
6. На каждом сервере проверить:
   - появление VPN в Android-шторке;
   - `session/start` 200;
   - `session/verify verified=True`;
   - YouTube;
   - 2ip/IP-check;
   - speedtest;
   - стабильность после блокировки/разблокировки экрана;
   - reconnect после смены Wi-Fi/mobile, без агрессивного forced reconnect.
7. Отдельно проверить split-tunnel domains на `2ip.ru`, если эта функция включена в текущей APK.
8. Отдельно проверить Quick Settings Tile, если тестируется APK с изменениями от 2026-05-18+.
9. Отдельно проверить негативный сценарий: нет подписки -> paywall/402, без попытки поднять VPN.

Открытые риски перед запуском:
- опубликованная APK от 2026-05-19 может не включать самые последние изменения контекста после этой даты, если они были только `compileReleaseKotlin` без сборки APK;
- нужно подтвердить, что именно эта APK является кандидатом на запуск;
- user_id=23 имеет старые неактивные device rows с `is_vpn_enabled=true`, но свежий GRANIwg device row не активен; это нужно наблюдать, если UI покажет ложное состояние;
- если тесты начинаются с expired-доступом, результаты будут ложными из-за ожидаемых `402`.

## Обновление 2026-05-26 09:10 MSK — критичный pre-launch риск: VPN продолжает работать после окончания подписки

Наблюдение пользователя:
- пользователь был в приложении под аккаунтом `railcuber@gmail.com` / user_id=23;
- приложение было в фоне;
- тестовая подписка закончилась;
- VPN продолжал работать до ручного отключения через Android VPN-шторку.

Факты backend/DB:
- последние подписки user_id=23 имеют status `expired`;
- последняя Google Play test subscription:
  - id=39;
  - start `2026-05-25 19:45:29 UTC`;
  - end `2026-05-25 19:50:29 UTC`;
  - status `expired`;
- после истечения доступа backend начал отдавать ожидаемые `402 Нет активного VPN-доступа` на:
  - `/api/simple-vpn/session/verify`;
  - `/api/simple-vpn/servers`;
  - `/api/simple-vpn/protocols`;
  - `/api/simple-vpn/session/start`.

Почему VPN не отключился:
- текущая проверка доступа работает как gate для новых API-запросов и verify/config/start;
- уже поднятый GRANIwg/WireGuard dataplane не зависит от дальнейших HTTP-ответов backend;
- если peer остается на сервере и Android VPN локально не остановлен, трафик продолжает идти;
- backend `402` сам по себе не отзывает peer и не посылает команду stop в Android;
- приложение в фоне может не обработать `402` так, чтобы немедленно вызвать native stop.

Вывод:
- это отдельный критичный запусковой баг entitlement enforcement;
- оплаты могут корректно переводить подписку в `expired`, но доступ фактически не отзывается у уже подключенного VPN;
- перед запуском нужен hard revoke path, иначе пользователь с истекшей подпиской сможет пользоваться VPN до ручного отключения/перезапуска/смены сети.

Что должно стать целевым поведением:
1. При истечении/отзыве подписки backend должен помечать активные VPN-сессии пользователя как stopped/revoked.
2. Backend должен отзывать active/prepared GRANIwg peers на всех серверах для пользователя/device/public_key или помечать их revoked так, чтобы reconnect/cache не продолжался.
3. Клиент при любом `402` на `session/verify`, `bootstrap`, `servers`, `protocols`, `config` во время активного VPN должен:
   - остановить native VPN локально;
   - убрать Android VPN notification/tile active state;
   - показать paywall/сообщение “доступ закончился”.
4. Клиент должен делать entitlement check на resume и периодически во время active VPN, чтобы фоновой сценарий не зависел от ручного открытия приложения.
5. Quick Settings Tile при expired access должен разрешать только disconnect, но не reconnect.

Тест для фикса:
1. Выдать user_id=23 короткую Google Play test subscription на 5 минут.
2. Подключить GRANIwg к IE-DUB-01.
3. Убедиться: `session/start 200`, `session/verify verified=True`, YouTube/2ip работают.
4. Оставить приложение в фоне до истечения подписки.
5. Ожидание после фикса: в течение заданного grace/TTL VPN должен отключиться сам, peer должен быть удален/заблокирован, повторный connect должен открыть paywall/вернуть 402.
6. Проверить, что Android-шторка больше не показывает активный VPN.

Статус на момент записи:
- код не менялся;
- проблема подтверждена как архитектурная: payment status и live VPN dataplane сейчас не связаны жестким revoke-механизмом.

## Обновление 2026-05-26 09:40 MSK — entitlement revoke / быстрый reconnect после оплаты

Что сделано по критичному багу “подписка закончилась, а VPN продолжает работать”:
- добавлен backend-сервис `backend/services/simple_vpn_entitlement.py`;
- `device_server_peers` расширяется колонками:
  - `suspended_at`;
  - `suspend_reason`;
  - `revoked_reason`;
- soft-expiry теперь не удаляет подготовленный GRANIwg профиль, а переводит его в suspended:
  - live peer снимается с WireGuard/AmneziaWG сервера;
  - device помечается inactive / `is_vpn_enabled=false`;
  - `current_server_id`, `ip_address`, `vpn_protocol` сбрасываются;
  - prepared peer/IP/config остаются в базе для быстрого восстановления после оплаты;
- hard revoke для refund/chargeback/voided purchase помечает peer как revoked и также снимает live peer с сервера;
- `_assert_access()` в `/api/simple-vpn/*` теперь при отсутствии trial/subscription запускает `suspend_user_graniwg_access(...)` перед возвратом `402`;
- `vpn.check_subscription_expiry` теперь при истечении подписки не только ставит `expired`, но и suspend-ит GRANIwg доступ пользователя;
- Google Play RTDN теперь suspend/revoke-ит доступ на событиях:
  - `SUBSCRIPTION_EXPIRED` -> soft suspend;
  - `SUBSCRIPTION_ON_HOLD` -> soft suspend;
  - `SUBSCRIPTION_REVOKED` -> hard revoke;
  - voided purchases -> hard revoke.

Быстрый reconnect после оплаты:
- prepared peer не удаляется при обычном expiry/on-hold;
- после оплаты пользователь снова получает доступ к `/simple-vpn/config`;
- если найден suspended prepared peer, backend заново добавляет тот же public_key/vpn_ip на выбранный сервер и очищает `suspended_at/suspend_reason`;
- клиент может использовать старый локальный cached config, но session/start всё равно проходит через backend entitlement gate.

Что сделано в mobile-клиенте:
- `SimpleVpnApi` теперь переводит HTTP `402` в typed `SimpleVpnAccessRequiredException`;
- `SimpleVpnController` при `402` во время connect/verify/options:
  - останавливает native AmneziaWG/WireGuard VPN локально;
  - вызывает `/simple-vpn/session/stop` с reason `subscription_required`;
  - очищает active session id;
  - выставляет `accessRequired=true`;
- добавлен периодический entitlement check во время active VPN: каждые 60 секунд через `/simple-vpn/session/verify`;
- при resume/native sync также выполняется entitlement verify;
- `CleanAmneziaHomeScreen` при `accessRequired=true` открывает маршрут `/subscription` в режиме expired.

Deploy/verification:
- backend Python syntax: `python3 -m py_compile backend/services/simple_vpn_entitlement.py backend/api/simple_vpn.py backend/api/payments.py backend/services/tasks/vpn_tasks.py` — OK;
- Flutter analyze по измененным файлам — OK;
- backend containers restarted: `granivpn_api`, `granivpn_celery`, `granivpn_beat`;
- API после restart healthy;
- DB columns verified in `device_server_peers`: `suspended_at`, `suspend_reason`, `revoked_reason`;
- собрана release APK: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
- опубликовано:
  - `https://api.granilink.com/downloads/app-release.apk`;
  - `https://api.granilink.com/downloads/grani-vpn-20260526-entitlement-revoke.apk`;
- SHA256 APK: `a02e35cd438c43fd7e3e183c8f05740592c500d35e1d67b661d31a7a50c4495b`;
- HTTP HEAD download проверен: `200`, content-type `application/vnd.android.package-archive`, content-length `87354972`, cache-control `no-store`.

Следующий тест для пользователя:
1. Установить APK от 2026-05-26: `https://api.granilink.com/downloads/app-release.apk`.
2. Авторизоваться и купить/получить короткую test subscription.
3. Подключить GRANIwg, лучше IE-DUB-01 как базовый сервер.
4. Проверить YouTube/2ip, затем оставить приложение в фоне до окончания test subscription.
5. Ожидание после фикса:
   - серверный peer будет снят expiry task/402 gate;
   - в новой APK при ближайшем verify/resume клиент локально остановит VPN;
   - быстрый reconnect без активной подписки должен открыть `/subscription` и не поднимать tunnel;
   - после новой оплаты reconnect должен пройти быстро на прежнем prepared profile/IP.

Оставшийся риск:
- если приложение полностью убито системой и до hourly expiry task ещё далеко, локальный Android VPN может не получить мгновенную команду stop, но backend-side peer removal через expiry task/первый 402 теперь должен закрывать dataplane; для более жесткого SLA можно добавить отдельный short-interval entitlement sweeper.

## Обновление 2026-05-26 12:35 MSK — аудит pre-launch теста Google Play / trial / device-limit

Тест пользователя:
- аккаунт: `railcuber@gmail.com` / user_id=23;
- установка из Google Play;
- сценарий: очистка приложения, Google auth, проверка device-limit на 6-м устройстве, удаление устройства, старт trial, подключение VPN.

Наблюдения пользователя:
1. Google authorization шла очень долго.
2. Окно лимита устройств появилось, первое удаление было долгим и неуспешным.
3. На trial screen нет выбора протокола и сервера.
4. VPN в Android-шторке уже подключен и трафик работает, но экран приложения бесконечно крутит состояние подключения.
5. Появилась надпись `Быстрое восстановление`, хотя данные приложения перед тестом были очищены.
6. Тексты процесса подключения на trial screen выглядят не как в старой кнопке.
7. Нет счетчика оставшегося trial-времени.

Факты из backend/client logs:
- Google callback быстрый: `POST /api/auth/google/callback` около `08:59:56 UTC`, `dt_ms=47.1`, HTTP 200.
- `/api/auth/me`, `/api/vpn/bootstrap`, `/api/vpn/control-plane-snapshot` также быстрые, примерно единицы-десятки ms.
- Device-limit сработал корректно: `DEVICE_LIMIT_EXCEEDED` на `device/resolve` и `device/register`.
- Device delete на backend был быстрый:
  - `09:00:10 UTC`, `dt_ms=138.3`, HTTP 200;
  - `09:00:29 UTC`, `dt_ms=78.3`, HTTP 200;
  - `09:00:34 UTC`, `dt_ms=83.6`, HTTP 200.
- Неуспешность первого удаления связана не с долгим backend, а с duplicate device rows: подготовка теста оставила несколько rows с одинаковым `device_id`; старый endpoint удалял только одну row, поэтому distinct device count мог не уменьшиться.
- Первый `/api/simple-vpn/config` занял `10887.8 ms`: создание/добавление peer.
- Повторный `/api/simple-vpn/config` cache-hit занимал до `3897.6 ms` из-за лишнего SSH runtime reconcile даже для несuspended prepared peer.
- Client log показал `connected_local`, то есть native VPN применился; проблема была в маппинге UI-состояния, а не в dataplane.

Найденные причины:
1. Долгая авторизация, судя по backend, не backend callback; вероятнее задержка в Google SDK/account chooser/клиентском переходе через device-limit flow. Нужна дополнительная client-side auth timing телеметрия, если задержка повторится.
2. Первое удаление устройства могло быть визуально неуспешным из-за duplicate rows с одним `device_id`.
3. Trial screen использует `ConnectionBlock`, где глобальный compact/minimal режим скрывал timer, speed, protocol selector и server selector.
4. Trial screen считал `VpnUiSessionState.connectedWarm` как `connecting`; поэтому VPN уже работал, но UI оставался на бесконечном spinner и не показывал connected/timer.
5. `Быстрое восстановление` появлялось из двух мест:
   - visible flow badge на trial screen;
   - в `VpnService._connectStageGetConfig` GRANIwg после API config ошибочно мог получать `ConnectionFlowType.warmCacheReconnect` по ветке `config != null`.
6. Тексты подключения были усилены неправильным stuck-state: UI оставался на стадии проверки защищенного трафика вместо перехода в connected.

Что изменено без сборки APK:
- `backend/api/vpn.py`:
  - `/api/vpn/device/delete` теперь удаляет все rows пользователя с одинаковым string `device_id`;
  - чистит связанные `ConnectionLog`, `ClientLog`;
  - отвязывает `TelemetryEvent` и `ObservabilityEvent`;
  - возвращает `remaining_devices` как distinct count.
- `backend/api/simple_vpn.py`:
  - для active prepared peer cache-hit убран лишний SSH runtime reconcile;
  - suspended prepared peer по-прежнему восстанавливается через добавление peer на сервер;
  - ожидаемый эффект: повторный `/simple-vpn/config` должен быть заметно быстрее.
- Backend API перезапущен: `granivpn_api` healthy.

Что изменено в mobile-коде, но требует новой сборки/Google Play обновления:
- `mobile-app/lib/widgets/connection_block.dart`:
  - добавлен per-instance `compactMode`;
  - default остается compact для home screen, чтобы не сломать текущий layout;
  - trial screen может включать полный режим с selectors/timer/speed.
- `mobile-app/lib/screens/trial_unified_screen.dart`:
  - `connectedWarm` теперь считается `connected`, а не `connecting`;
  - trial screen передает `compactMode: false`;
  - visible flow badge на trial screen скрыт, чтобы не показывать пользователю техническое `Быстрое восстановление`.
- `mobile-app/lib/services/vpn_service.dart`:
  - `/simple-vpn/config` теперь получает выбранный `server_id`; раньше client log мог показывать выбранный сервер, но backend выдавал default server;
  - GRANIwg больше не переводится в `warmCacheReconnect` просто потому, что `config != null`.

Проверки:
- `python3 -m py_compile backend/api/vpn.py backend/api/simple_vpn.py` — OK.
- `/opt/flutter/bin/dart format` по измененным Dart-файлам — OK.
- `/opt/flutter/bin/flutter analyze` по измененным Dart-файлам:
  - критических ошибок по новым правкам нет;
  - остаются старые warnings в `vpn_service.dart` про unused fields/elements;
  - остаются style info `prefer_const` в `trial_unified_screen.dart`.
- `granivpn_api` после restart: healthy.

Текущий статус:
- Backend-часть исправления device delete и ускорения prepared peer cache-hit уже применена на сервере.
- UI-исправления trial screen не попадут в установленную Google Play APK до новой сборки/публикации.
- Сборка APK на этом шаге намеренно не выполнялась, потому что тест идет через Google Play и пользователь отдельно отметил не делать пересборку без необходимости.

Рекомендуемый следующий тест без новой сборки:
1. Повторить device-limit удаление на текущей Google Play APK: endpoint уже обновлен, duplicate device rows больше не должны оставлять лимит после удаления.
2. Повторить connect на том же аккаунте и сервере: первый config может быть долгим при создании peer, повторный prepared cache-hit должен стать быстрее.
3. UI trial screen на текущей APK по-прежнему может крутиться бесконечно, потому что это client-side fix и он требует новой сборки.

Рекомендуемый следующий тест после новой Google Play сборки:
1. Очистить приложение.
2. Авторизоваться через Google.
3. На trial screen проверить наличие server/protocol selectors.
4. Подключиться к GRANIwg.
5. Ожидание: после появления VPN в Android-шторке UI должен перейти в connected, показать счетчик trial-времени, не показывать `Быстрое восстановление`.
6. Проверить сопровождающие тексты подключения и connected-state рядом со старой кнопкой/ожидаемыми copy.

## Обновление 2026-05-26 12:55 MSK — декомпозиция долгой Google authorization

Цель:
- пользователь должен попадать с нажатия Google login на целевой экран максимум за 10 секунд в нормальной сети;
- если есть device-limit, до 10 секунд должно появиться окно лимита, а не бесконечный spinner.

Факты по тесту `railcuber@gmail.com`:
- backend Google callback не был узким местом:
  - `POST /api/auth/google/callback` около `08:59:56 UTC`, `dt_ms=47.1`, HTTP 200;
- `/api/auth/me`, `/api/vpn/bootstrap`, `/api/vpn/control-plane-snapshot` быстрые, примерно 3-32 ms;
- `device/register/delete/devices` на backend тоже быстрые, десятки ms;
- значит секунды уходили не в backend callback, а в client-side Google SDK / secure storage / post-login orchestration / ожидание device-limit flow.

Проблема старой телеметрии:
- в `AuthService.signInWithGoogle()` событие `[auth-timing] google_auth_done` логировалось до `_saveToken(...)`;
- из-за этого measured auth time не включал secure storage, `notifyListeners()`, `StartScreen` post-login шаги и навигацию;
- пользователь видел “авторизация идет”, а наши auth logs уже считали ее завершенной.

Post-login блокировки, найденные в `StartScreen`:
1. `authService.signInWithGoogle()`;
2. `refreshControlPlaneSnapshot(... force: true)` — раньше awaited до навигации;
3. `PushNotificationService().syncPushTokenWithCurrentSession()` — раньше awaited до навигации;
4. analytics;
5. `_registerDeviceOrShowLimit(...)` — блокирующий device registration / device-limit modal;
6. навигация на target route.

Решение по UX/SLA:
- критичным блокирующим шагом после Google callback должен оставаться только `device_register_or_limit`, потому что это бизнес-правило лимита устройств;
- `control-plane snapshot` и `push-token sync` не должны держать пользователя на start screen;
- эти шаги переведены в background после успешной авторизации и регистрации устройства.

Что изменено в mobile-коде, требует новой сборки:
- `mobile-app/lib/services/auth_service.dart`:
  - добавлен `[auth-timing] save_token elapsed_ms=...`;
  - `google_auth_done total_ms=...` теперь логируется после `_saveToken(...)` и `notifyListeners()`;
  - в итог добавлены `callback_ms`, `save_token_ms`, `notify_ms`.
- `mobile-app/lib/screens/start_screen.dart`:
  - добавлен `[auth-timing] start_screen_auth_service_done`;
  - добавлен `[auth-timing] start_screen_route_decision`;
  - добавлен `[auth-timing] start_screen_device_register_or_limit_done`;
  - добавлен `[auth-timing] start_screen_navigation_done`;
  - `refreshControlPlaneSnapshot` переведен в background: `[auth-timing] start_screen_control_plane_snapshot_bg_done`;
  - `syncPushTokenWithCurrentSession` переведен в background: `[auth-timing] start_screen_push_token_bg_done`.

Ожидаемая новая декомпозиция в logcat:
1. `google_ui` — сколько заняло системное окно/Google SDK account picker.
2. `google_token` — получение id/access token от Google.
3. `callback_start` / `google_auth_done callback_ms` — backend callback.
4. `save_token` — secure storage.
5. `start_screen_auth_service_done` — весь AuthService как видит StartScreen.
6. `start_screen_device_register_or_limit_done` — регистрация устройства или появление лимита.
7. `start_screen_navigation_done` — реальное время до перехода с login screen.
8. Background markers для snapshot/push-token — должны приходить уже после navigation и не влиять на perceived login time.

SLA для следующего теста:
- normal login без лимита:
  - `start_screen_navigation_done total_ms <= 10000`;
  - `callback_ms < 1500`;
  - `save_token_ms < 1000`;
  - `device_register_or_limit_done elapsed_ms < 3000`;
- login с лимитом:
  - окно лимита должно появляться до 10 секунд;
  - после удаления устройства повторная регистрация должна занимать < 3 секунд при нормальной сети.

Проверки:
- `/opt/flutter/bin/dart format lib/services/auth_service.dart lib/screens/start_screen.dart` — OK.
- `/opt/flutter/bin/flutter analyze lib/services/auth_service.dart lib/screens/start_screen.dart`:
  - ошибок нет;
  - остались существующие warning/info: unused `_fadeAnimation`, несколько `prefer_const`, `prefer_conditional_assignment`.

Статус:
- ускорение perceived auth и декомпозиция внесены только в mobile-код;
- backend менять не потребовалось;
- без новой Google Play сборки текущая установленная APK этих изменений не содержит.

## Обновление 2026-05-26 13:15 MSK — новый визуал главной кнопки GraniConnectSurfaceButton

Задача:
- заменить визуал главной кнопки подключения на мягкую фирменную поверхность GRANI;
- не менять layout экрана;
- не менять business logic;
- не менять connection state machine;
- не собирать APK на этом шаге.

Что сделано:
- добавлен новый dumb UI-компонент:
  - `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`;
  - API близок к ТЗ:
    - `state`;
    - `onPressed`;
    - `title`;
    - `subtitle`;
    - `size`, default `250`;
    - дополнительные accessibility поля `semanticsLabel`, `semanticsHint`;
- добавлен UI enum `VpnConnectionState`:
  - `disconnected`;
  - `connecting`;
  - `disconnecting`;
  - `connected`;
  - `error`;
- текущий `mobile-app/lib/widgets/button_connection.dart` сохранен как adapter:
  - внешний API `ButtonConnectionState`, `onTap`, `progressMessage`, `errorMessage`, `progressPercent`, `scaleX/scaleY` оставлен для существующих экранов;
  - adapter маппит старые состояния в новый `GraniConnectSurfaceButton`;
  - haptic feedback и tap debounce сохранены;
  - VPN connect/disconnect logic не затронута.

Визуальные решения:
- размер кнопки по умолчанию: `250 logical px`;
- внешний контейнер — круг;
- внутреннее кольцо около `210 logical px` (`size * 0.84`);
- soft surface через слои:
  - внешний круг с мягкой нижней тенью;
  - верхняя светлая подсветка;
  - внутренний круг с linear gradient `#FFFFFF -> #F8FAFD -> #EDF2F7`;
  - имитация inset через мягкие внутренние shadow/highlight слои;
- orange ring:
  - disconnected: тонкое приглушенное orange кольцо;
  - connecting/disconnecting: вращающаяся дуга около 70% окружности, period 1200 ms;
  - connected: полный orange ring + спокойное breathing glow, period 3600 ms;
  - error: спокойное красное состояние через тот же surface layout;
- press feedback:
  - `AnimatedScale` до `0.975`;
  - тень уменьшается;
  - inset/glow корректируются;
- `BackdropFilter`, glassmorphism, сильный blur > 45 не используются.

Тексты внутри кнопки:
- title берется из существующей локализации:
  - off: `btnVpnConnect`;
  - connecting: `btnVpnConnecting`;
  - disconnecting: `btnVpnDisconnecting`;
  - on: `btnVpnConnected`;
  - error: `btnVpnRetry`;
- subtitle берется из существующей локализации:
  - off: `homeServiceReady`;
  - connecting: `vpnProgressProtocolStart`;
  - disconnecting: `homeDisconnectingSubtitle`;
  - on: `homeConnectionActive`;
  - error: `errorMessage` или `homeConnectionFailed`.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart lib/widgets/connection_block.dart` — OK, `No issues found`.

Статус:
- изменение внесено только в mobile-код;
- APK не собирался;
- текущая Google Play APK не содержит новый визуал;
- перед публикацией стоит визуально проверить на Android, потому что кнопка увеличена с прежних ~205 до 250 logical px и может потребовать мелкой вертикальной подстройки, если на маленьком экране будет тесно.

## Обновление 2026-05-26 13:25 MSK — собрана 64-bit APK с новой кнопкой

Сборка:
- команда/скрипт: `/opt/grani/build_release_apk.sh`;
- Flutter build: `flutter build apk --release --target-platform android-arm64`;
- результат:
  - `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
  - `/opt/grani/granivpn-release-arm64.apk`;
- размер: около `84M`;
- SHA256: `3028d43697cd77e5ecc1426fcf134dc3d5bae7d9f6db6cf3176c4dc09f74439a`;
- ABI проверка через `unzip -l`: внутри только `lib/arm64-v8a/...`, значит сборка 64-bit arm64.

Публикация для скачивания:
- обновлен простой URL:
  - `https://api.granilink.com/downloads/app-release.apk`;
- уникальный URL:
  - `https://api.granilink.com/downloads/grani-vpn-20260526-arm64-button.apk`;
- `curl -I` по обоим актуальным URL вернул HTTP `200`, content-type `application/vnd.android.package-archive`, content-length `87421068`, cache-control `no-store`.

Важно:
- имя `grani-vpn-20260526-arm64-surface-button.apk` сначала было проверено до копирования в активный nginx mount и получило Cloudflare cached `404`; для теста использовать `grani-vpn-20260526-arm64-button.apk` или `app-release.apk`.

## Обновление 2026-05-26 13:50 MSK — корректировка disconnected/off визуала кнопки

Причина:
- первая реализация `GraniConnectSurfaceButton` в off-состоянии выглядела слишком оранжевой:
  - полный orange ring;
  - теплый glow подсвечивал центральную область;
  - subtitle делал кнопку перегруженной;
- по макету disconnected/off должен быть почти белой встроенной шайбой:
  - оранжевым остается в основном power icon;
  - без full orange ring;
  - без subtitle;
  - с более заметным мягким внешним углублением.

Что изменено только для `disconnected/off`:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - для `VpnConnectionState.disconnected` отключен orange glow;
  - отключен отдельный CustomPaint ring для disconnected;
  - добавлены отдельные холодные бело-серые слои внешнего бортика/углубления;
  - центральная шайба уменьшена до `size * 0.84`, чтобы визуально соответствовать внутреннему кругу макета;
  - контент без subtitle смещен и отцентрирован отдельно от active-состояний;
- `mobile-app/lib/widgets/button_connection.dart`:
  - для `ButtonConnectionState.off` subtitle теперь пустой (`''`);
  - остальные состояния не менялись намеренно, потому что их дизайн будет рассматриваться отдельно.

Не менялось:
- connecting/connected/error визуал;
- layout экранов;
- business logic;
- connection state machine.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK, `No issues found`.

Статус:
- правка внесена в mobile-код;
- новая APK после этой правки еще не собиралась.

## Обновление 2026-05-26 14:05 MSK — корректировка connecting визуала кнопки

Причина:
- первая реализация `connecting` выглядела как плоская оранжевая полоска и давала ощущение оранжевой "шайбы";
- по макету состояние подключения должно оставаться светлой встроенной кнопкой, а движение должно читаться как теплый летящий свет по окружности.

Что изменено только в визуале `connecting/disconnecting`:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - для `connecting/disconnecting` теперь используется такая же глубокая бело-серая поверхность, как основа off-кнопки;
  - убрана большая центральная оранжевая подсветка, чтобы поверхность оставалась светлой;
  - оранжевая дуга переписана в `CustomPainter` как многослойная:
    - тонкий теплый базовый трек;
    - основной движущийся arc с градиентом от прозрачного хвоста к теплому оранжевому;
    - локальный blur/glow только вокруг дуги;
    - дополнительный короткий highlight-arc, чтобы движение выглядело ближе к макету с двумя световыми участками;
  - power icon, тексты и этапы подключения не менялись.

Не менялось:
- business logic;
- connection state machine;
- тексты/этапы процесса подключения;
- сборка APK не запускалась.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK, `No issues found`.

## Обновление 2026-05-26 15:13 MSK — believable/pass кнопки + сборка APK

Задача:
- сделать кнопку менее "рендерной" и более believable/production-premium;
- после правок собрать APK для проверки на устройстве.

Что изменено в `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
- материал:
  - добавлен статичный procedural micro-noise внутри центральной поверхности (`_SurfaceMaterialPainter`), без jpeg/asset;
  - добавлен тонкий edge reflection по верхне-левой дуге;
  - добавлен едва заметный нижний ambient light, чтобы glow не был идеально равномерным;
- connected:
  - breathing замедлен с `3600ms` до `5600ms`;
  - ring/glow ослаблены примерно на 30-40%;
  - connected теперь должен читаться спокойнее: steady warm light вместо тревожной активности;
- connecting:
  - rotation замедлен с `1200ms` до `1650ms`;
  - основной sweep сделан чуть короче (`52%` окружности);
  - добавлен более мягкий световой переход в "голове" сегмента;
  - цель: ощущение energy sweep, а не обычного loader/spinner;
- error:
  - красный заменен на более мягкий warm coral (`_coralPrimary/_coralLight`);
  - glow и ring дополнительно ослаблены;
  - ошибка должна восприниматься как "система столкнулась с проблемой", а не тревожная авария;
- press response:
  - существующий scale сохранен;
  - при нажатии материал получает чуть более собранный внутренний свет через `_SurfaceMaterialPainter`.

Про нагрузку:
- texture/noise статичный и рисуется в `CustomPainter`, без анимации;
- анимируются только ring/glow, `RepaintBoundary` вокруг `CustomPaint` сохранен;
- blur не увеличивался сверх прежних рамок;
- expected impact: интерфейс стал тяжелее старой простой кнопки, но не должен влиять на сам VPN tunnel/connect pipeline; главный риск — только UI overdraw/fps на слабых Android, поэтому connected intentionally замедлен и ослаблен.

Проверки перед сборкой:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK, `No issues found`.

Сборка:
- команда: `/opt/grani/build_release_apk.sh`;
- Flutter build: release `android-arm64`;
- результат:
  - `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
  - `/opt/grani/granivpn-release-arm64.apk`;
- размер: `84M`;
- SHA256: `15f64647ef5465856f82824d88b7ddc67d580e9e63d0d1ee5f219f79c9c8cc34`.

Публикация:
- стабильная ссылка:
  - `https://api.granilink.com/downloads/app-release.apk`;
- уникальная ссылка этой сборки:
  - `https://api.granilink.com/downloads/grani-vpn-20260526-believable-button.apk`;
- `curl -I` по обеим ссылкам вернул HTTP `200`, `content-type: application/vnd.android.package-archive`, `content-length: 87421068`, `content-disposition: attachment`.

## Обновление 2026-05-26 15:39 MSK — локализация журнала/серверов + центрирование launcher icon

Причины:
- после очистки приложения интерфейс мог стартовать на английском, потому что `LocaleController` по умолчанию всегда ставил `en`;
- экран журнала уведомлений показывал часть старых/серверных payload как английский текст (`Payment received`, `While app open`, `From notification tap`);
- sheet выбора сервера содержал hardcoded русский текст;
- launcher icon был визуально смещен, у знака было мало равномерного воздуха вокруг.

Что изменено:
- `mobile-app/lib/core/session/locale_controller.dart`:
  - первый запуск теперь выбирает язык системы (`ru`/`en`), а не всегда `en`;
  - если системный язык неподдерживаемый, fallback остается `en`;
- `mobile-app/lib/screens/notification_journal_screen.dart`:
  - добавлена нормализация stored notification entries;
  - если в записи есть `data.event`, title/body берутся из текущей локализации;
  - для старых записей на русском интерфейсе переводятся типовые английские title/body:
    - `Payment received` → `Оплата получена`;
    - `"1 месяц" extended until ...` → `«1 месяц» продлена до ...`;
    - типовые subscription/trial messages → русские тексты;
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`:
  - hardcoded `Сервер`/`Нет доступных GRANIwg серверов` заменены на локализованные строки;
  - fallback label `Server/Сервер` теперь зависит от locale;
- `mobile-app/lib/widgets/bottom_sheets/server_selector_bottom_sheet.dart`:
  - убрана неиспользуемая private loading-заглушка и лишний import;
  - оставлена локализованная загрузка/пустое состояние через существующие l10n keys;
- Android launcher icon:
  - пересобраны density PNG для `mipmap-*/ic_launcher.png`;
  - пересобраны adaptive foreground PNG `drawable-*/ic_launcher_foreground.png`;
  - пересобран `drawable/ic_launcher_monochrome.png`;
  - знак уменьшен и отцентрирован, чтобы сверху/снизу/по бокам была пустота.

Проверки:
- `/opt/flutter/bin/dart format lib/core/session/locale_controller.dart lib/screens/notification_journal_screen.dart lib/screens/main/clean_amnezia_home_screen.dart lib/widgets/bottom_sheets/server_selector_bottom_sheet.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/core/session/locale_controller.dart lib/screens/notification_journal_screen.dart lib/screens/main/clean_amnezia_home_screen.dart lib/widgets/bottom_sheets/server_selector_bottom_sheet.dart` — OK, `No issues found`;
- первая попытка build через `/opt/grani/build_release_apk.sh` показала stale APK fallback, потому что временные `.pre-center.bak` иконок лежали внутри `res`;
- `.pre-center.bak` файлы удалены из `android/app/src/main/res`;
- прямой build `flutter build apk --release --target-platform android-arm64` — OK.

Сборка:
- APK: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
- опубликован как:
  - `https://api.granilink.com/downloads/app-release.apk`;
  - `https://api.granilink.com/downloads/grani-vpn-20260526-l10n-icon.apk`;
- SHA256: `f7e59858d3e23bc2563750867b4a5482c13496ea6be1d254e44e50d7cc8fc1c6`;
- `curl -I` по обеим ссылкам вернул HTTP `200`, `content-type: application/vnd.android.package-archive`, `content-length: 87399288`, `content-disposition: attachment`.

## Обновление 2026-05-26 15:55 MSK — исправление ускоренного сгорания trial

Проблема:
- у `railcuber@gmail.com` trial был начат `2026-05-26 10:34:38 UTC`, но уже был `trial_active=false`, `trial_seconds_left=0`;
- при этом полный trial должен был действовать до `2026-05-27 10:34:38 UTC`;
- причина системная: `get_trial_seconds_left()` каждый вызов считал `elapsed = now - trial_started_at`, вычитал его из `trial_seconds_left` и сохранял уменьшенное значение обратно;
- из-за частых `/auth/me`, `/bootstrap`, `/simple-vpn` elapsed вычитался повторно из уже уменьшенного остатка, поэтому trial мог закончиться намного раньше 24 часов.

Что исправлено:
- `backend/services/trial_service.py`;
- `backend/application/services/trial_service.py`;
- `backend/services/tasks/notification_tasks.py`.

Новая логика:
- `trial_seconds_left` больше не уменьшается при каждом чтении;
- для trial с `trial_started_at` remaining считается как:
  - `max(0, max(trial_seconds_left, 86400) - elapsed)`;
- если trial был ошибочно выключен, но `trial_started_at` моложе 24 часов, сервис автоматически возвращает `trial_active=true` и `trial_seconds_left=86400`;
- Celery expiry task теперь тоже использует минимум 24 часа, а не уже испорченное/уменьшенное значение.

Восстановление данных:
- выполнен update для всех пользователей, у кого `trial_started_at` моложе 24 часов и trial был выключен или имел меньше 86400 секунд;
- затронут `1` пользователь:
  - `railcuber@gmail.com`;
  - `trial_active=true`;
  - `trial_seconds_left=86400`;
  - `trial_started_at=2026-05-26 10:34:38 UTC`.

Проверки:
- `python3 -m py_compile services/trial_service.py application/services/trial_service.py services/tasks/notification_tasks.py` — OK;
- backend service check для user id `23`:
  - `service_remaining` около `78294` секунд;
  - после вызова `trial_seconds_left` в базе остался `86400`, то есть повторное чтение больше не сжигает время;
- перезапущены контейнеры:
  - `granivpn_api`;
  - `granivpn_celery`;
  - `granivpn_beat`;
- все три контейнера поднялись, `granivpn_api` healthy.

Важно:
- APK не нужен: это backend-only fix;
- пользователям с новым trial теперь доступны полные 24 часа от `trial_started_at`;
- старые trial старше 24 часов не восстановлены.

## Обновление 2026-05-26 16:15 MSK — второй решительный pass disconnected-кнопки без APK

Контекст:
- после сравнения реализации с макетом стало ясно, что проблема не только в размере;
- текущая кнопка слишком сильно читалась как "круг внутри круга" / neumorphism;
- цель: приблизить disconnected/off к логике `surface + soft recess + inner core`, а не к набору видимых окружностей.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - disconnected `ringSize` уменьшен с `0.725` до `0.70`, чтобы контур/канавка были ближе к внутреннему ядру, а не к жесткой внешней геометрии;
  - inner surface уменьшена с `0.735` до `0.70`;
  - outer bowl увеличен до `1.10`, trough до `0.94`, чтобы появился визуальный воздух между внешней поверхностью и recessed center;
  - чистый белый заменен на более теплые soft-white/grey-white оттенки (`#FCFDFF`, `#F7F9FC`, `#EFF3F8`);
  - тень disconnected сделана шире и слабее:
    - blur до `74/86`;
    - opacity снижена;
    - добавлен большой рассеянный ambient shadow;
  - жесткие border/line на trough и inner surface ослаблены;
  - base ring для disconnected больше не рисуется как отдельная четкая окружность;
  - quiet ring стал тоньше и мягче (`1.15px`) с меньшей opacity;
  - shadow/highlight arcs в disconnected размыты сильнее и стали менее читаемыми как геометрические линии;
  - content block для disconnected сдвинут ниже и лучше центрируется внутри recessed surface;
  - power icon увеличен, title/subtitle слегка пересобраны по пропорциям;
- `mobile-app/lib/widgets/button_connection.dart`:
  - для `off` возвращен subtitle:
    - RU: `Нажмите для защиты`;
    - EN: `Tap to protect`;
  - без subtitle композиция не попадала в макет.

Не менялось:
- business logic;
- connection state machine;
- active/connected/error поведение;
- APK не собирался по явной просьбе пользователя.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK, `No issues found`.

## Обновление 2026-05-26 14:45 MSK — уточнение: отдельный визуал для disconnecting/«Отключение»

Уточнение:
- пользователь имел в виду не `off/disconnected`, а состояние `disconnecting` / «Отключение»;
- предыдущая правка off/error остается в коде, но для отключения была нужна отдельная ветка.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - `connecting` и `disconnecting` больше не используют одну и ту же ветку отрисовки;
  - `connecting` сохранен как энергичный "летящий свет";
  - `disconnecting` сделан как спокойное затухание:
    - обратное направление вращения;
    - более короткая основная дуга (`40%` окружности вместо `58%`);
    - меньшая толщина дуги (`3.4px` вместо `4.6px`);
    - слабее glow;
    - короткий fading-tail вместо второго активного яркого участка.

Не менялось:
- тексты состояний;
- business logic;
- connection state machine;
- сборка APK не запускалась.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK, `No issues found`.

## Обновление 2026-05-26 17:55 MSK — переход disconnected-кнопки на bitmap surface asset без APK

Причина:
- pure Flutter/CustomPaint-подход не давал убедительный премиальный recessed surface:
  - слишком легко скатывался в "серые круги с тенями";
  - сложный свет reference-кнопки трудно стабильно повторить через `Container`, `BoxShadow`, `CustomPaint`;
  - golden/headless preview дополнительно искажал шрифты/иконки.
- принято решение использовать гибрид:
  - bitmap-подложка отвечает за материал, свет, чашу и посадочное место;
  - Flutter сверху продолжает рисовать power icon, title/subtitle, states, tap-scale/haptic.

Что изменено:
- добавлен asset:
  - `mobile-app/assets/images/grani_connect_surface_base.png`;
  - источник: предоставленный пользователем PNG `ChatGPT Image 26 мая 2026 г., 17_25_03.png`;
  - asset подготовлен как center crop 1050x1050 с мягкой radial alpha-маской по краям, чтобы не было квадратной плашки на фоне приложения;
  - SHA256 на DO: `11d246eaee487da446f312438ce70d91eebcd3a7b89d637cb37dd799c8547aed`.
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - добавлен `_surfaceAsset = 'assets/images/grani_connect_surface_base.png'`;
  - для `VpnConnectionState.disconnected` теперь используется `Image.asset` как подложка `250x250`;
  - поверх asset остаются текущие Flutter icon/title/subtitle;
  - procedural `_OuterSurface`/ring painter для disconnected больше не используется;
  - connecting/connected/disconnecting/error пока оставлены на текущей Flutter-реализации, чтобы не ломать анимации и state-machine.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK, `No issues found`;
- локальный preview PNG на фоне `#F7F9FC` показывает, что asset визуально близок к требуемой кнопке и не дает квадратного фона.

Ограничение проверки:
- временный Flutter golden-render в headless-среде оказался ненадежен для `Image.asset`:
  - без `precacheImage` asset не попал в снимок;
  - с явным `precacheImage` тест завис;
  - поэтому этот путь не используется как финальная визуальная проверка для bitmap asset.

Не менялось:
- business logic;
- connection state machine;
- тексты;
- APK не собирался.

## Обновление 2026-05-26 17:35 MSK — recessed bowl pass для disconnected без APK

Причина:
- после light-driven pass кнопка стала светлее, но внешняя выемка почти исчезла;
- пользователь уточнил цель: исправлять не центр, а посадочное место вокруг него;
- визуальная цель: `button seated inside a soft recessed bowl`, а не `circle inside circle`.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - добавлен отдельный `_RecessedBasinPainter` только для disconnected outer basin;
  - painter рисует посадочное место светом, без жестких линий:
    - верхний soft highlight внешней чаши;
    - нижнюю inner valley shadow между центральным диском и чашей;
    - нижнюю ambient shadow внешнего бассейна;
    - верхний inner lip highlight;
  - outer bowl/trough стали немного шире (`1.20` / `1.08`);
  - bottom falloff внешнего bowl усилен, чтобы выемка читалась как мягкое углубление в поверхности;
  - центральная поверхность намеренно не менялась.

Текущий визуальный вывод:
- код теперь разделяет центральный диск и посадочную чашу отдельным световым слоем;
- в golden-render эффект все еще выглядит очень тонким из-за headless рендера/масштаба, но направление правки правильное: глубина создается не border, а light falloff.

Не менялось:
- business logic;
- connection state machine;
- тексты;
- APK не собирался.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK, `No issues found`;
- сделан временный golden-render disconnected без APK.

## Обновление 2026-05-26 17:15 MSK — light-driven pass disconnected-кнопки без APK

Причина:
- предыдущий disconnected pass улучшил геометрию, но кнопка все еще читалась как набор серых кругов и теней;
- новый ориентир: не geometry-driven UI, а light-driven surface render:
  - слои должны растворяться в свете;
  - depth создается ambient lighting и highlights, а не видимыми границами;
  - темные тени должны быть почти незаметными.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - dark shadows в disconnected сильно ослаблены и расширены;
  - outer bowl переведен с плоского серого цвета на мягкий radial ambient gradient;
  - добавлен white ambient wash на центральной поверхности;
  - усилены soft white highlights сверху/снизу;
  - warm reflection оставлен очень слабым, чтобы кольцо не выглядело линией;
  - layer borders стали почти невидимыми;
  - quiet ring и нижняя тень ослаблены, чтобы убрать эффект "серых кругов".

Текущий визуальный вывод:
- кнопка стала светлее и атмосфернее;
- отдельные окружности читаются меньше;
- есть риск, что center surface стал слишком стерильным/плоским — следующий pass, если потребуется, должен вернуть контролируемую глубину в центр без темных серых разделителей.

Не менялось:
- business logic;
- connection state machine;
- остальные состояния;
- APK не собирался.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK, `No issues found`;
- сделан временный golden-render disconnected без APK.

## Обновление 2026-05-26 16:55 MSK — геометрический pass disconnected-кнопки без APK

Причина:
- по сравнению с новым референсом disconnected-состояние все еще ощущалось как "круг внутри круга";
- цель pass: приблизить кнопку к логике "мягкая поверхность + углубление + ядро", а не добавлять новые эффекты.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - увеличен perceived air между внешним мягким слоем, канавкой и центральной поверхностью;
  - disconnected `ringSize` увеличен с `0.70` до `0.76`, чтобы контур ближе соответствовал макету;
  - центральная поверхность disconnected увеличена с `0.70` до `0.76`;
  - outer bowl/trough расширены (`1.18` и `1.06`) и сделаны мягче;
  - темные тени стали шире и слабее, чтобы убрать локальную "неоморфную" тень;
  - границы и warm ring ослаблены, чтобы круги меньше читались как отдельная геометрия;
  - контент disconnected уменьшен и визуально спокойнее:
    - power icon чуть меньше;
    - title/subtitle меньше и ближе к референсу;
    - блок слегка центрирован спокойнее внутри recessed surface.

Не менялось:
- business logic;
- connection state machine;
- остальные состояния целенаправленно не пересобирались под новый макет;
- APK не собирался.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK, `No issues found`;
- сделан временный golden-render disconnected без APK; в headless Flutter иконка/кириллица могут отображаться некорректно, но геометрия слоев видна.

## Обновление 2026-05-26 14:35 MSK — проектирование и реализация off/error визуала кнопки

Причина:
- отдельных макетов для off/error нет, поэтому эти состояния спроектированы как продолжение главного макета кнопки;
- цель: не плодить разные визуальные языки, а сохранить одну премиальную бело-серую "встроенную" поверхность.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - `disconnected/off`:
    - теперь тоже рисуется через `CustomPaint`, а не остается без контура;
    - добавлен очень тонкий спокойный warm ring поверх нейтрального трека;
    - состояние читается как "готово к подключению", без активного свечения и без агрессивного orange ring;
  - `error`:
    - переведен на ту же глубокую бело-серую базу;
    - центральная поверхность остается светлой;
    - красный акцент приглушен и перенесен в контур/углубление:
      - мягкий red glow в канавке;
      - тонкое красное кольцо;
      - легкая красная внутренняя подсветка бортика;
    - иконка остается красной, как единственный явный сигнал ошибки.

Не менялось:
- тексты состояний;
- business logic;
- connection state machine;
- сборка APK не запускалась.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK, `No issues found`.

## Обновление 2026-05-26 14:20 MSK — корректировка connected визуала кнопки

Причина:
- текущая реализация `connected` была слишком плоской и оранжевой:
  - центральная область визуально заливалась теплым цветом;
  - полное кольцо выглядело слишком толстым/агрессивным;
  - глубина кнопки была слабее, чем в базовом макете.

Что изменено только в визуале `connected`:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - `connected` теперь использует ту же глубокую бело-серую базу, что off/connecting;
  - центральная поверхность остается светлой, без оранжевой заливки;
  - оранжевое свечение перенесено в углубления/обод:
    - мягкий warm glow в наружной канавке;
    - локальный blur вокруг полного кольца;
    - тонкая теплая внутренняя подсветка бортика;
  - полное connected-кольцо сделано спокойнее и тоньше (`2.6px` вместо активной толстой полосы);
  - breathing-анимация теперь реально влияет на теплое свечение (`_breathingController` прокинут в surface/ring painter).

Не менялось:
- business logic;
- connection state machine;
- тексты состояний;
- сборка APK не запускалась.

Проверки:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK, `No issues found`.

## Обновление 2026-05-26 — приведение кнопки к рендеру состояний без APK

Запрос пользователя:
- сверить `off/disconnected` кнопку с рендером 5 состояний;
- поправить текст/элементы off-кнопки;
- заложить правильную модель динамики для `connect/disconnect/connected/error`.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`
  - bitmap surface `assets/images/grani_connect_surface_base.png` теперь используется как единая базовая поверхность для всех состояний, а не только для `disconnected`;
  - активные состояния (`connecting`, `disconnecting`, `connected`, `error`) рисуют только state-ring/glow поверх той же поверхности, ближе к референсу;
  - текст внутри кнопки переведен в верхний регистр на уровне виджета;
  - контентный блок поднят выше и сделан компактнее;
  - уменьшены размеры title/subtitle, power icon приведен к более спокойной пропорции;
  - error-title допускает две строки.
- `mobile-app/lib/widgets/button_connection.dart`
  - `connecting` subtitle теперь берет живой `progressMessage`, если он есть, вместо статичного текста;
  - `error` title теперь показывает `homeConnectionFailed`, а не `btnVpnRetry`;
  - `error` subtitle берет `errorMessage`, если он есть.

Как должна быть устроена динамика по рендеру:
- `off`: статичная мягкая поверхность, минимум свечения, только orange power icon + title/subtitle;
- `connecting`: тот же surface, движущийся orange energy sweep по окружности, subtitle отражает текущий stage (`Создаём защищённый канал`, `Проверяем защищённый трафик` и т.п.);
- `disconnecting`: тот же surface, обратное/затухающее движение дуги, короче и спокойнее чем connect;
- `connected`: полный тонкий orange ring + очень медленное breathing glow, без агрессивного loader feeling;
- `error`: тот же surface, мягкий coral/red ring + warning/error content, без аварийного яркого красного.

Проверка:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.

Статус:
- правки загружены на `/opt/grani/mobile-app`;
- business logic/connect pipeline не менялись;
- APK не собирался.

## Обновление 2026-05-26 — второй pass кнопки по рендеру состояний без APK

Запрос пользователя:
- показать текущие состояния кнопки рядом с рендером;
- внести правки, чтобы состояния выглядели ближе к reference: off/connect/disconnect/connected/error.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`
  - error-состояние теперь использует `Icons.warning_amber_rounded`, а не power icon;
  - base-track активных состояний сделан тоньше и спокойнее;
  - `connecting` energy sweep стал легче: меньше stroke/glow, короче secondary tail, меньше ощущение обычного loader;
  - `disconnecting` сделан еще тише: короче дуга, слабее glow, тоньше fading-tail;
  - `connected` breathing glow ослаблен, ring остался тонким и steady;
  - `error` ring/glow ослаблен и переведен в мягкое coral-состояние.

Текущая модель динамики:
- `off`: статичная surface, orange power icon, title/subtitle;
- `connecting`: движущийся warm energy segment по кольцу + stage subtitle из `progressMessage`;
- `disconnecting`: обратное затухающее движение, меньше энергии чем connect;
- `connected`: полный тонкий ring + медленное спокойное breathing glow;
- `error`: warning icon + soft coral ring/glow.

Проверка:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.

Статус:
- правки загружены на `/opt/grani/mobile-app`;
- business logic/connect pipeline не менялись;
- APK не собирался.

## Обновление 2026-05-26 — третий pass кнопки по тонким отличиям от оригинала без APK

После сравнения с original render выполнен еще один визуальный pass:
- контентный блок поднят выше, чтобы icon/title/subtitle сидели ближе к reference;
- title/subtitle облегчены: меньше размер, `FontWeight.w700` вместо более тяжелого `w800`, subtitle светлее;
- power icon стал немного меньше и менее контрастный;
- active ring size немного уменьшен и получил мягкий inset-shadow, чтобы контур читался как лежащий в материале, а не наложенный поверх PNG;
- connecting ring стал тоньше, с меньшим glow и более коротким secondary tail;
- disconnecting ring еще спокойнее: shorter fading arc, lower opacity/glow;
- connected ring тоньше, добавлен мягкий lower amber glow для теплого дыхания снизу/справа;
- error ring/glow ослаблен и сделан более молочно-coral, icon остается warning.

Проверка:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.

Статус:
- правка загружена на `/opt/grani/mobile-app`;
- business logic/connect pipeline не менялись;
- APK не собирался.

## Обновление 2026-05-26 — gradient falloff для свечения/теней кнопки без APK

Запрос пользователя:
- тени и свечение выглядят топорно;
- нужно сделать затухания/градиент, чтобы свет был мягче и ближе к оригинальному рендеру.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`
  - base-track активных состояний переведен с плоского цвета на `SweepGradient` с прозрачными зонами;
  - transition glow для `connecting/disconnecting` теперь рисуется градиентом: прозрачный хвост -> мягкий warm -> яркая голова -> затухание;
  - connected glow переведен на градиентные sweep-ореолы, включая отдельный нижний warm glow;
  - error glow переведен на мягкий coral sweep-gradient, без равномерной красной обводки;
  - inset-shadow под кольцом оставлен, но теперь работает вместе с gradient falloff, чтобы ring воспринимался как в материале.

Проверка:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.

Статус:
- правка загружена на `/opt/grani/mobile-app`;
- business logic/connect pipeline не менялись;
- APK не собирался.

## Обновление 2026-05-26 — depth overlay + custom glyph pass кнопки без APK

Запрос пользователя:
- выполнить следующий pass после сравнения с оригиналом;
- усилить ощущение материала/глубины и убрать системность иконок.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`
  - добавлен `_SurfaceStateOverlayPainter` поверх bitmap surface:
    - мягкий radial bowl-depth;
    - верхний lip highlight;
    - state aura для `connecting/disconnecting/connected/error`;
    - connected получает более широкий lower amber aura;
    - error получает более молочный coral aura;
  - Material icons заменены на кастомный `_ButtonGlyphPainter`:
    - power glyph рисуется тонким arc/line с небольшим highlight;
    - warning glyph рисуется кастомным треугольником и mark;
  - это снижает ощущение Android Material icon и приближает кнопку к рендеру.

Проверка:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.

Статус:
- правка загружена на `/opt/grani/mobile-app`;
- business logic/connect pipeline не менялись;
- APK не собирался.

## Обновление 2026-05-26 — soft arc pass: убраны топорные оранжевые дуги без APK

Запрос пользователя:
- оранжевые дуги выглядят страшно и топорно;
- нужно убрать жесткий progress-bar вид.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`
  - transition stroke уменьшен с `2.4` до `1.5`;
  - connected stroke уменьшен до `1.6`, error до `1.35`;
  - base-track opacity для active/error состояний сильно снижен;
  - `connecting` main arc стал короче, тоньше и полупрозрачнее;
  - `connecting` glow теперь шире, но слабее, чтобы восприниматься как рассеянный свет, а не линия;
  - `disconnecting` arc стал еще короче и почти затухающим;
  - connected/error ring opacity снижены, glow оставлен как основной носитель состояния;
  - hot-spot/tail сегменты приглушены.

Проверка:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.

Статус:
- правка загружена на `/opt/grani/mobile-app`;
- business logic/connect pipeline не менялись;
- APK не собирался.

## Обновление 2026-05-26 — исправление резких оранжевых дуг и power glyph без APK

Запрос пользователя:
- на zoom-превью оранжевые дуги выглядят страшно/топорно;
- у power glyph виден лишний хвостик справа.

Что изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`
  - основной active stroke еще сильнее смягчен: transition `1.5`, connected `1.6`, error `1.35`;
  - base-track opacity снижена почти вдвое;
  - `connecting` main arc короче и полупрозрачнее, glow шире и слабее;
  - `disconnecting` arc стал еще короче и мягче;
  - connected/error ring стали менее графичными, акцент перенесен в мягкий glow;
  - power glyph исправлен: gap теперь сверху, stroke тоньше, удален лишний highlight, который давал правый хвостик.

Проверка:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.

Статус:
- правка загружена на `/opt/grani/mobile-app`;
- business logic/connect pipeline не менялись;
- APK не собирался.
### 2026-05-26 21:50 MSK — кнопка VPN: рассеянный свет вместо жестких дуг

- Задача: приблизить свет активного кольца к референсу, где оранжевый не выглядит жесткой дугой, а читается как рассеянное теплое свечение вокруг чаши.
- Сделано без сборки APK: обновлен `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`.
- Технически свет переведен в многослойную схему:
  - широкий нижний radial wash в `_SurfaceStateOverlayPainter`;
  - широкий blurred halo для connected/transition в `_GraniConnectRingPainter`;
  - отдельный мягкий средний ореол;
  - тонкая верхняя hairline-линия кольца без полной непрозрачности.
- Убрана причина видимого шва на правой стороне full-circle кольца: у connected/error endpoints sweep-gradient теперь совпадают по прозрачности/цвету.
- Для connecting/disconnecting снижена плотность основной оранжевой дуги: активный процесс теперь строится как мягкое свечение + тонкий translucent stroke, а не тяжелая оранжевая линия.
- Проверка: `/opt/flutter/bin/dart format` и `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — успешно, `No issues found`.
- APK не собирался.


### 2026-05-26 22:12 MSK — кнопка VPN: уплотнение свечения после сравнения с референсом

- Задача: свечение появилось, но выглядело слишком жидким/водяным по сравнению с референсом.
- Сделано без сборки APK: обновлен `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`.
- Коррекция:
  - connected-аура стала плотнее: выше opacity, шире нижний radial wash, меньше чрезмерного blur у среднего слоя;
  - connected-ring усилен: линия немного толще, amber-слои плотнее рядом с кольцом, разлет света оставлен мягким;
  - connecting/disconnecting дуги стали насыщеннее, но остаются через glow + тонкий stroke без тяжелых торцов;
  - error-состояние получило более плотный coral-glow и чуть заметнее кольцо.
- Проверка: `/opt/flutter/bin/dart format` и `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — успешно, `No issues found`.
- APK не собирался.
### 2026-05-26 22:15 MSK — кнопка VPN: усиление свечения после повторного сравнения с оригиналом

- Задача: свечение все еще выглядело слабее оригинального рендера.
- Сделано без сборки APK: обновлен `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`.
- Усиление:
  - connected-аура поднята до более заметного amber-halo;
  - добавлен/усилен плотный rim-body слой вокруг нижней половины чаши;
  - outer/middle/inner glow у connected стали шире и насыщеннее;
  - основное connected-кольцо чуть толще и ярче, но с сохранением мягкого окружения;
  - connecting/disconnecting и error также получили более видимый glow, чтобы соответствовать референсу по плотности света.
- Проверка: `/opt/flutter/bin/dart format` и `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — успешно, `No issues found`.
- APK не собирался.
### 2026-05-26 22:26 MSK — кнопка VPN: внутренняя рельса, толстое кольцо и градиент свечения

- Задача: по скрину рельса активной оранжевой дуги должна быть ближе к белой кнопке; кольцо должно быть толще; свечение должно быть плотным у кольца и более жидким к внешнему краю.
- Сделано без сборки APK: обновлен `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`.
- Изменения:
  - active rail сдвинута внутрь через `railInset` внутри `_GraniConnectRingPainter`, без уменьшения canvas под внешний glow;
  - active stroke утолщен: connected до ~3.35 px, connecting до ~3.05 px, disconnecting до ~2.8 px, error до ~2.45 px;
  - base rail/track оставлен тоньше, чтобы толстая оранжевая дуга ехала по отдельной внутренней дорожке;
  - `_drawTransitionGlow` разделен на два слоя: плотный body-glow на самой рельсе и более жидкий outer-glow на увеличенном радиусе;
  - `_drawConnectedGlow` разделен на внешний mist-слой и более плотные near-body/middle/inner слои рядом с оранжевым кольцом.
- Проверка: `/opt/flutter/bin/dart format` и `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — успешно, `No issues found`.
- APK не собирался.
### 2026-05-26 22:36 MSK — кнопка VPN: радикальная правка рельсы, толщины и защиты верха от amber-glow

- Задача: текущая оранжевая дуга не попадала в отмеченную рельсу, толщина визуально почти не отличалась, рассеивание не читалось, верх кнопки желтел/оранжевел вопреки дизайну.
- Сделано без сборки APK: обновлен `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`.
- Радикальные изменения:
  - active rail возвращена к внешней дорожке (`railInset` почти убран), чтобы дуга проходила по отмеченной рельсе;
  - active stroke резко увеличен: connected ~5.2 px, connecting ~4.7 px, disconnecting ~4.25 px, error ~3.6 px;
  - connected glow больше не рисуется full-circle: все amber-свечение ограничено нижней дугой через `clipRect`, верх кнопки защищен от пожелтения;
  - surface aura для connecting/disconnecting отключена, чтобы верхняя часть кнопки не грелась общей оранжевой аурой;
  - connected glow разделен на защищенный нижний outer-mist и плотные near-body/middle/inner слои рядом с кольцом;
  - transition glow оставлен следовать только за движущейся дугой и разделен на внешний жидкий слой + плотный body-слой.
- Проверка: `/opt/flutter/bin/dart format` и `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — успешно, `No issues found`.
- APK не собирался.
### 2026-05-26 22:53 MSK — кнопка VPN: общий радиус рельсы/дуги/glow и защитный cap-слой

- Задача: пользователь указал, что свет не плотный, рельса и желтая дуга не синхронизированы по радиусу, а желтое свечение может перекрывать кнопку; предложил закрыть свечение дополнительным слоем кнопки без выемки.
- Сделано без сборки APK: обновлен `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`.
- Конструктивные изменения:
  - `ringSize` для активных состояний увеличен до `size * 0.84`, чтобы рельса/дуга ушли на внешний визуальный радиус;
  - активная дуга и base-track теперь используют один и тот же `rect/radius`, без отдельного смещения рельсы;
  - active stroke заметно увеличен: connected ~6.2 px, connecting ~5.8 px, disconnecting ~5.2 px, error ~4.6 px;
  - добавлен `_drawInnerSurfaceShield`: чистый внутренний cap-диск поверх glow и перед активной дугой, чтобы свечение не окрашивало поверхность кнопки;
  - connected glow усилен и рисуется только нижней дугой, наружу от кольца, с клипом от верхней части кнопки;
  - transition glow остается привязанным к движущейся дуге и рисуется на том же радиусе.
- Проверка: `/opt/flutter/bin/dart format` и `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — успешно, `No issues found`.
- APK не собирался.

### 2026-05-28 09:55 MSK — кнопка VPN: остановлен неудачный premium-эксперимент, возвращен стабильный 2D fallback

- Причина: после серии правок и ручного preview пользователь подтвердил, что текущий "premium surface" визуал не годится для продукта: кнопка не попадает в референс по материалу/свету и выглядит хуже ожидаемого.
- Решение: активный production-виджет не продолжаем "лечить тенями"; вместо этого возвращаем контролируемую простую 2D-кнопку с тем же публичным API и теми же состояниями.
- Сделано без сборки APK:
  - переписан `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`;
  - убраны зависимость от bitmap `assets/images/grani_connect_surface_base.png` и сложная псевдо-3D имитация чаши;
  - оставлены 5 состояний: disconnected, connecting, disconnecting, connected, error;
  - состояние подключения/отключения рисуется как простая анимированная orange-дуга;
  - connected рисуется как спокойное полное orange-кольцо с мягким pulse;
  - error рисуется через muted coral-кольцо и warning glyph;
  - бизнес-логика, connect pipeline, debounce, тексты и state machine не менялись.
- Важно по дизайну:
  - для настоящего попадания в premium reference нужен отдельный design handoff: Figma/слои или clean raster assets для 5 состояний без baked-текста;
  - дальнейшие попытки вручную имитировать reference в Flutter без source-слоев признаны рискованными для запуска.
- Проверка:
  - `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.
- APK не собирался.

### 2026-05-28 10:35 MSK — кнопка VPN: подключены bitmap-ассеты тарелки/центра

- Пользователь подготовил два PNG-ассета:
  - `tar.png` -> `mobile-app/assets/images/grani_button_bowl_base.png`;
  - `kn.png` -> `mobile-app/assets/images/grani_button_center_source.png`.
- Оба ассета проверены локально:
  - размер `1024x1024`;
  - формат с alpha-channel (`Format32bppArgb`);
  - у `tar.png` есть почти полный мягкий visual footprint, пригоден как общая чаша/тарелка;
  - у `kn.png` более компактный bbox и он подключен как дополнительный центральный слой поверх тарелки.
- Изменен `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - `_ButtonSurface` теперь строится из bitmap-слоев `Image.asset`;
  - Flutter больше не рисует базовый материал кнопки контейнерами/градиентами;
  - текст, power/error glyph, animated arcs и state glow остаются Flutter-слоями поверх bitmap-base;
  - business logic, connect pipeline, debounce и state machine не менялись.
- Текущий подход:
  - base material берется из ассетов;
  - дальше отдельно добиваем glow/дуги через Flutter painter или отдельные PNG overlays.
- Проверка:
  - `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.
- APK не собирался.

### 2026-05-28 10:50 MSK — кнопка VPN: подключены PNG glow/ring overlays для connected/error

- Пользователь подготовил два PNG-ассета дуг со свечением:
  - `дуга подключено.png` -> `mobile-app/assets/images/grani_button_glow_connected.png`;
  - `дуга эррор.png` -> `mobile-app/assets/images/grani_button_glow_error.png`.
- Проверка ассетов:
  - оба файла `1024x1024`;
  - оба RGBA с alpha-channel;
  - центр и углы прозрачные, черный фон не запечен в пиксели.
- Изменен `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - добавлены constants `_connectedGlowAsset` и `_errorGlowAsset`;
  - для `connected` и `error` поверх bitmap-base теперь рисуется PNG overlay с ring/glow;
  - старое Flutter-рисование full connected/error ring отключено, чтобы не было двойного кольца;
  - connecting/disconnecting по-прежнему используют Flutter animated arc;
  - business logic, connect pipeline, debounce и state machine не менялись.
- Проверка:
  - `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.
- APK не собирался.

### 2026-05-28 11:05 MSK — кнопка VPN: подключены вращающиеся PNG overlays для connecting/disconnecting

- Пользователь подготовил два PNG-ассета дуги/свечения для переходных состояний:
  - `подключение дуга.png` -> `mobile-app/assets/images/grani_button_glow_connecting.png`;
  - `отключение.png` -> `mobile-app/assets/images/grani_button_glow_disconnecting.png`.
- Проверка ассетов:
  - оба файла `1024x1024`;
  - оба RGBA с alpha-channel;
  - центр и углы прозрачные, фон не запечен.
- Изменен `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - добавлены constants `_connectingGlowAsset` и `_disconnectingGlowAsset`;
  - `connecting` теперь использует PNG overlay и вращается по часовой стрелке;
  - `disconnecting` теперь использует PNG overlay и вращается против часовой стрелки;
  - старое Flutter-рисование moving arc для connecting/disconnecting отключено, чтобы не было двойной дуги;
  - `connected/error` остаются на своих PNG glow overlays;
  - business logic, connect pipeline, debounce и state machine не менялись.
- Проверка:
  - `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.
- APK не собирался.

### 2026-05-28 12:05 MSK — кнопка VPN: финальные тексты/иконки и preview APK

- Доведён UI-слой кнопки поверх bitmap-ассетов:
  - power glyph используется для disconnected/connecting/disconnecting/connected;
  - warning glyph используется для error;
  - иконки остаются Flutter-слоем поверх PNG base/glow, не запечены в ассеты.
- В `mobile-app/lib/widgets/button_connection.dart` для визуальной кнопки заданы короткие согласованные тексты по состояниям:
  - `disconnected`: `Подключить` / `Нажмите для защиты`;
  - `connecting`: `Подключение...` / `Создаём защищённый канал`;
  - `disconnecting`: `Отключение...` / `Завершаем соединение`;
  - `connected`: `Подключено` / `Соединение защищено`;
  - `error`: `Не удалось подключиться` / `Проверьте сеть и попробуйте снова`.
- Английские варианты также заданы локально в adapter для визуальной кнопки.
- Глобальные l10n ARB-файлы не менялись, чтобы не затронуть тексты других экранов.
- Проверка:
  - `/opt/flutter/bin/dart format lib/widgets/button_connection.dart lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/widgets/button_connection.dart lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.
- Собран ARM64 release APK:
  - source: `mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
  - size: `93.4MB`;
  - sha256: `eb66fdf3e67442c20a51304ac4bf4dcf954d5dd47402249924c0119445cb1027`.
- APK опубликован:
  - `https://api.granilink.com/downloads/app-release.apk`;
  - серверный `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `content-disposition: attachment`, `cache-control: no-store`.

### 2026-05-28 21:37 MSK — кнопка VPN: убрана лишняя окружность поверх bitmap-ассетов

- По скриншоту пользователя в состоянии `Подключить` была видна лишняя темная нижняя дуга/окружность, которой не было в PNG-ассетах.
- Причина найдена в `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`: поверх bitmap-base оставались два Flutter `CustomPaint` слоя:
  - `_SurfaceLightPainter` рисовал темную нижнюю тень и дополнительные рефлексы;
  - `_RingPainter` рисовал idle-track/idle-ring для disconnected-состояния.
- Эти слои конфликтовали с layered-assets подходом и создавали визуальный артефакт поверх ассета.
- Исправление:
  - убран `_RingPainter` из Stack;
  - удален `_SurfaceLightPainter`;
  - удален неиспользуемый `_track` color constant;
  - glyph/text/state overlays оставлены без изменений.
- Проверка:
  - `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.
- APK не собирался.

### 2026-05-28 21:59 MSK — кнопка VPN: увеличен размер, приглушены transition-дуги и проверены тексты отключения

- По скриншотам пользователя:
  - кнопка выглядела слишком мелкой и не была доминантой экрана;
  - PNG-дуги/свечение в `connecting/disconnecting` перекрывали тарелку;
  - transition-состояния давали равномерное свечение по всему периметру;
  - нужно было проверить, не совпадают ли тексты отключения с подключением.
- Изменено:
  - `mobile-app/lib/widgets/button_connection.dart`
    - дефолтный размер `ButtonConnection` увеличен с `250` до `330` px (+32% на базовом 412px layout);
  - `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`
    - дефолтный размер `GraniConnectSurfaceButton` также увеличен до `330` px;
    - state PNG overlays теперь кладутся между `bowl_base` и `center_source`, чтобы центральный cap экранировал лишнее свечение на поверхности кнопки;
    - для `connecting/disconnecting` убрано активное круговое ambient-glow через `BoxShadow`, оставлен только мягкий базовый фон;
    - transition PNG overlays стали прозрачнее (`connecting` ~0.58, `disconnecting` ~0.52);
    - поверх transition overlays добавлена Flutter `ShaderMask` с `SweepGradient`, чтобы обрывать полное PNG-свечение по дуге с плавным fade-in/fade-out без Photoshop;
    - `connected/error` overlays также чуть приглушены, чтобы не забивать материал тарелки.
- Проверка текстов:
  - `ButtonConnection` уже содержит отдельные строки для отключения: `Отключение...` / `Завершаем соединение`, EN `Disconnecting...` / `Closing connection`;
  - home/trial l10n также имеют отдельные строки: `homeDisconnecting`, `homeDisconnectingSubtitle`, `trialUiDisconnectingTitle`, `trialUiDisconnectingSubtitle`;
  - совпадения с текстами подключения в проверенных runtime-экранах не найдено.
- Проверка:
  - `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — OK, `No issues found`.
- Расширенный analyze по home/trial показал только старые предупреждения в соседних файлах (`unused_import`, `use_build_context_synchronously`, `prefer_const_*`), не связанные с этой правкой.
- APK не собирался.

### 2026-05-28 22:15 MSK — собран и опубликован APK после правок кнопки

- В сборку вошли последние UI-правки кнопки VPN:
  - удаление лишней окружности/нижней дуги поверх bitmap-ассетов;
  - увеличение кнопки с `250` до `330` px;
  - перенос state PNG overlays между `bowl_base` и `center_source`;
  - приглушение `connecting/disconnecting` overlays;
  - `ShaderMask`/`SweepGradient` fade для плавного обрыва transition-свечения без Photoshop;
  - проверенные отдельные тексты отключения.
- Сборка:
  - команда: `/opt/flutter/bin/flutter build apk --release --target-platform android-arm64`;
  - source: `mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
  - size: `93.4MB`;
  - sha256: `d413f6201c5d4d6f913f855fd338e25cd87bdd718d5c60ac22214de3d6e462a7`.
- APK опубликован:
  - path: `/opt/grani/server-config/static-pages/downloads/app-release.apk`;
  - URL: `https://api.granilink.com/downloads/app-release.apk`;
  - серверный `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `content-length: 93388749`, `content-disposition: attachment`.

### 2026-05-28 23:25 MSK — cutover auth/control-plane на api.granilink.com

- Повод: в приложении при авторизации появился сетевой timeout; `granilink.com` истекает/выводится из эксплуатации, нужно переключить control-plane на `granilink.com`.
- Проверка доменов:
  - рабочий домен: `api.granilink.com` (A → `45.12.132.94`);
  - `api.grani-link.com` и `grani-link.com` не резолвятся;
  - `https://api.granilink.com/health` → `200`;
  - `https://api.granilink.com/api/vpn/bootstrap` → `200`;
  - `https://api.granilink.com/downloads/app-release.apk` → `200`.
- Логи nginx/API:
  - зафиксирован успешный `POST /api/auth/google/callback` через granilink-прокси со статусом `200`;
  - следом `GET /api/auth/me` также `200`;
  - значит backend и новый домен в момент проверки живые, а проблема была вероятнее в старом fallback/cache/сообщении приложения.
- Найденные остатки старого домена:
  - `server-config/.env`: `API_BASE_URL_FALLBACKS` всё ещё содержал `https://api.granilink.com/api`;
  - `backend/api/bootstrap.py` добавлял `https://api.granilink.com/api` и direct IP fallback в `api_base_urls`;
  - `mobile-app/lib/config/app_config.dart` держал direct-IP путь/SNI через `api.granilink.com`;
  - `mobile-app/lib/core/api/endpoint_router.dart` мог использовать старый direct fallback для refresh/vpnControl;
  - `mobile-app/lib/services/auth_service.dart` показывал hardcoded timeout-сообщение про `api.granilink.com`;
  - `mobile-app/android/.../XrayRoutingHelper.kt` держал `api.granilink.com` в control-plane direct domains.
- Изменено:
  - backend bootstrap теперь отдаёт только:
    - `https://api.granilink.com/api`;
    - `https://api.granilink.com:8444/api`;
  - `server-config/.env` fallback очищен до `https://api.granilink.com:8444/api`;
  - клиентский primary API остаётся `https://api.granilink.com/api`;
  - fallback для refresh/vpnControl переведен на `https://45.12.132.94:8444/api` с SNI/Host `api.granilink.com`;
  - control-plane direct domains/IPs в native routing переведены на `api.granilink.com` / `45.12.132.94`;
  - сообщение timeout теперь говорит про `api.granilink.com`.
- Применение:
  - `python3 -m py_compile backend/api/bootstrap.py` — OK;
  - `dart format` по измененным Dart-файлам — OK;
  - `flutter analyze lib/config/app_config.dart lib/core/api/endpoint_router.dart lib/core/api/preferred_route_storage.dart lib/services/auth_service.dart lib/services/connection_logger.dart --no-fatal-infos --no-fatal-warnings` — без warnings/errors, только старые info-style замечания;
  - API-контейнер пересобран: `docker compose -f server-config/docker/docker-compose.yml up -d --build api`;
  - после пересборки `bootstrap` подтвердил granilink-only список.
- Auth smoke:
  - `POST https://api.granilink.com/api/auth/send-code {}` → `422`, то есть endpoint доступен и отвечает валидацией, не timeout;
  - `POST https://api.granilink.com/api/auth/google/callback {}` → `422`, endpoint доступен;
  - `POST https://api.granilink.com:8444/api/auth/send-code {}` → `422`, fallback-port доступен.
- Собран и опубликован новый ARM64 APK:
  - source: `mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
  - URL: `https://api.granilink.com/downloads/app-release.apk`;
  - size: `93.4MB`;
  - sha256: `984e9116a9c98c4210cb7d9506016ec6d60d457b3dd93aec48bd043c12907754`;
  - `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `cache-control: no-store`.
- Проверка строк APK:
  - есть `https://api.granilink.com/api`;
  - есть `https://api.granilink.com:8444/api`;
  - рабочего `api.granilink.com` в строках APK больше нет.

### 2026-05-28 23:45 MSK — premium pass по главной VPN-кнопке без APK-сборки

По выводам о текущем качестве кнопки сделан следующий проход в `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`.

Что изменено:
- усилен connected glow: добавлен отдельный painter с более широким нижне-правым воздушным оранжевым ореолом за пределами тарелки;
- дуга стала не одиночным UI-stroke, а набором слоёв: мягкая blur-подложка + более плотный основной след + градиентная маска по краям;
- добавлен ceramic/material pass поверх surface: мягкий radial highlight в центре, верхний внутренний блик, деликатный rim light, лёгкий нижний объём;
- connecting/disconnecting переведены на более медленное и плавное движение: цикл 2800 ms, eased rotation через `Curves.easeInOutSine`, pulse включён для переходных состояний;
- error-состояние смягчено: красный сдвинут в coral, общий glow слабее и менее системный;
- добавлена более широкая мягкая нижняя тень, чтобы кнопка меньше “лежала” и больше парила;
- убраны analyzer-info по `prefer_const_declarations`.

Проверка:
- `/opt/flutter/bin/dart format /opt/grani/mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — No issues found.

Важно: APK после этого прохода не собирался. Следующая сборка нужна только после визуальной проверки/команды на выпуск, чтобы не повторять проблему с лишними сборками.

### 2026-05-28 23:55 MSK — APK после premium-pass кнопки

По команде собрана и опубликована новая release APK после правок главной VPN-кнопки.

Сборка:
- команда: `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release --target-platform android-arm64`;
- результат: `mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
- размер Flutter artifact: `93.4MB`.

Публикация:
- опубликовано в `server-config/static-pages/downloads/app-release.apk`;
- публичная ссылка: `https://api.granilink.com/downloads/app-release.apk?v=20260528-2355`;
- `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `cache-control: no-store`;
- размер по HTTP: `93388749` bytes.

Контроль:
- sha256: `acff5c3c3254e10bae99eb9e7828266a735f09d92b7255ce21039091964c4bfe`;
- проверка строк APK показала рабочие API URL только на `api.granilink.com`:
  - `https://api.granilink.com/api`;
  - `https://api.granilink.com:8444/api`;
  - старого рабочего `api.granilink.com` в строках APK нет.

### 2026-05-29 10:10 MSK — Cloudflare cutover для `api.granilink.com` и cleanup bootstrap

Повод:
- после перехода приложения на `api.granilink.com` без VPN авторизация/подключение стали нестабильными;
- в Cloudflare `api.granilink.com` сначала был `DNS only` на `45.12.132.94`, затем включён `Proxied`;
- нужно было понять, переносить ли API на основной IP и что делать с `:8444`.

Проверки:
- публичный DNS `api.granilink.com` после orange-cloud отдаёт Cloudflare IP (`104.21.8.58`, `172.67.138.153`);
- `https://api.granilink.com/api/vpn/bootstrap` через Cloudflare работает и отдаёт `200`;
- `https://api.granilink.com:8444/api/vpn/bootstrap` через Cloudflare не отвечает, что ожидаемо: этот порт не подходит для Cloudflare-proxied hostname;
- основной сервер `159.223.199.122` технически отдаёт bootstrap при `Host/SNI api.granilink.com`, но текущий origin-сертификат на основном сервере содержит только `granilink.com`, поэтому переводить A-запись `api.granilink.com` на основной IP без отдельного TLS/server_name pass рискованно;
- текущая схема `api.granilink.com` → Cloudflare → `45.12.132.94` → nginx proxy → основной API оставлена как безопасная рабочая схема для control-plane.

Изменено backend-only, без APK:
- `backend/api/bootstrap.py`: убран принудительный возврат `https://api.granilink.com:8444/api`;
- `server-config/.env`: `API_BASE_URL_FALLBACKS` очищен;
- `backend/tests/test_bootstrap_api.py`: ожидания обновлены под Cloudflare-only bootstrap.

Применение и контроль:
- `python3 -m py_compile /opt/grani/backend/api/bootstrap.py` — OK;
- API-контейнер пересобран и перезапущен: `docker compose -f server-config/docker/docker-compose.yml up -d --build api`;
- `GET https://api.granilink.com/api/vpn/bootstrap` теперь отдаёт только `["https://api.granilink.com/api"]`;
- `POST https://api.granilink.com/api/auth/send-code {}` → `422`, то есть auth endpoint доступен через Cloudflare и отвечает backend-валидацией;
- `pytest` внутри `granivpn_api` недоступен (`pytest` не установлен в runtime image), поэтому проверка ограничена py_compile + live smoke.

Важно:
- VPN endpoint’ы/порты не проксировать через Cloudflare;
- `api.granilink.com` можно держать orange-cloud, потому что это HTTP API;
- `api.granilink.com:8444` больше нельзя использовать как fallback для Cloudflare-proxied hostname. Если нужен emergency fallback, его нужно проектировать отдельно как direct-origin/IP fallback, а не как тот же hostname через Cloudflare.

### 2026-05-29 11:45 MSK — главная VPN-кнопка: новая база `kn2/kn3` и glow канавки

Повод:
- предыдущая bitmap-версия стала лучше, но визуально читалась как “тарелка”, а не как нажимаемая кнопка;
- пользователь подготовил новые прозрачные PNG:
  - `kn2.png` → `assets/images/grani_button_bowl_base_v2.png`;
  - `kn3.png` → `assets/images/grani_button_center_source_v2.png`;
- в новой базе канавка изменилась по ширине и положению; свечение должно работать не только наружу в чашу, но и внутрь к центральной кнопке.

Изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` переключён на v2 PNG assets;
- добавлен `_GrooveGlowPainter`: отдельный слой свечения канавки с двумя направлениями:
  - внешний широкий мягкий glow в сторону чаши;
  - внутренний более тонкий glow в сторону центральной кнопки;
- для `connecting`/`disconnecting` добавлены вращающиеся кодовые дуги канавки поверх PNG overlay:
  - подключение — по часовой стрелке;
  - отключение — против часовой стрелки;
- старые PNG glow overlays сохранены, но приглушены, чтобы не спорить с новой геометрией канавки;
- ослаблены лишние Flutter-тени/ceramic overlay, потому что материал теперь сильнее “запечён” в PNG;
- title/subtitle/icon уменьшены, чтобы вернуть больше воздуха внутри кнопки;
- исправлена power-иконка: вместо “палка + улыбка” теперь рисуется нормальный power glyph.

Проверка:
- `dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — No issues found.

Важно:
- APK после этой правки не собирался;
- следующий шаг — собрать preview APK только по отдельной команде и визуально проверить радиусы свечения на реальном экране.

### 2026-05-29 12:00 MSK — preview APK с новой кнопкой `kn2/kn3`

По команде собрана и опубликована ARM64 release APK для визуальной проверки новой кнопки на устройстве.

Сборка:
- команда: `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release --target-platform android-arm64`;
- результат: `mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
- Flutter artifact: `94.7MB`;
- опубликовано в `server-config/static-pages/downloads/app-release.apk` и `/opt/grani/granivpn-release-arm64.apk`.

Публичная ссылка:
- `https://api.granilink.com/downloads/app-release.apk?v=20260529-1200`;
- `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `content-length: 94745535`, `cache-control: no-store`, `cf-cache-status: BYPASS`.

Контроль:
- sha256: `0d3d78edc16e0952cb2106fae7b2e071b6656dbeb9ec1f4e59cde7a6e73bbbe5`.

### 2026-05-29 12:25 MSK — корректировка кнопки после просмотра preview APK

По скринам с устройства выявлено:
- цвет центральной кнопки и чаши выбивался из общего фона приложения;
- error-title `Could not connect` и часть subtitle были слишком широкими для внутреннего поля;
- glow попадал поверх центральной кнопки, хотя центральный PNG должен быть отдельной “крышкой” без засветки;
- connecting arc уходил наружу из канавки.

Изменено в `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
- порядок слоёв исправлен: все glow/arc слои теперь лежат под `grani_button_center_source_v2.png`, центральная кнопка перекрывает свечение;
- старые PNG glow overlays для connected/error/connecting/disconnecting отключены из рендера, потому что они были рассчитаны на старую геометрию и смещали дугу наружу;
- активная дуга теперь рисуется только `_GrooveGlowPainter` по радиусам канавки;
- bowl/center PNG слегка высветлены через `srcATop` white tint, чтобы материал меньше отличался от фона;
- button title/subtitle заменены на `_ScaleDownText`: текст автоматически ужимается по ширине внутреннего поля и не выезжает за кнопку;
- удалён старый `CeramicSurfacePainter`, чтобы кодовые блики не пачкали новый PNG-материал.

Проверка:
- `dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — No issues found.

Важно:
- APK после этой корректировки пока не собирался.

### 2026-05-29 13:40 MSK — замена на осветлённые PNG assets `kn4/kn5` и новая preview APK

Повод:
- пользователь подготовил новые assets с уже вырезанным фоном и осветлённым материалом:
  - `kn5.png` — новая полная чаша/база;
  - `kn4.png` — новая центральная кнопка;
- предыдущая корректировка высветляла PNG через Flutter `srcATop` tint, но теперь осветление запечено в самих ассетах, поэтому кодовый tint больше не нужен.

Изменено:
- новые PNG загружены в проект:
  - `mobile-app/assets/images/grani_button_bowl_base_v3.png`;
  - `mobile-app/assets/images/grani_button_center_source_v3.png`;
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` переключён на v3 assets;
- убран дополнительный white tint / `BlendMode.srcATop` с bowl и center `Image.asset`, чтобы Flutter не пересвечивал уже подготовленные изображения;
- порядок слоёв сохранён: glow/arc остаются под центральной кнопкой, центральный PNG не должен засвечиваться поверх.

Проверка:
- `dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — No issues found;
- собрана ARM64 release APK:
  - команда: `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release --target-platform android-arm64`;
  - результат Flutter: `build/app/outputs/flutter-apk/app-release.apk`, `96.1MB`;
  - опубликовано в `server-config/static-pages/downloads/app-release.apk` и `/opt/grani/granivpn-release-arm64.apk`.

Публичная ссылка:
- `https://api.granilink.com/downloads/app-release.apk?v=20260529-1340`;
- `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `content-length: 96107021`, `cache-control: no-store`, `cf-cache-status: BYPASS`;
- sha256: `15a3606bc88094a6ea65b56997222907e8a0990ee7b65ac61bd8564c43801480`.

### 2026-05-29 14:15 MSK — корректировка положения дуг в канавке кнопки

Повод:
- после осветления v3 assets кнопка стала гармоничнее с фоном приложения;
- по скринам с устройства дуги и glow активных состояний оказались слишком далеко наружу: визуально ехали по внешней кромке тарелки, а не по канавке вокруг центральной кнопки;
- целевая логика: яркая дуга должна идти по “рельсе” канавки, а мягкий свет должен расходиться на кромку канавки и внутрь к центральной кнопке, не заливая саму кнопку сверху.

Изменено в `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
- `_GrooveGlowPainter` переведён с двух больших окружностей `0.348/0.405 * size` на одну рабочую rail-окружность около `0.296 * size`, что ближе к фактической канавке v3 PNG;
- для `connecting` и `disconnecting` теперь рисуются два сегмента на одной рельсе, а не внешний/внутренний дубль на разных радиусах:
  - `connecting` продолжает движение по часовой стрелке;
  - `disconnecting` продолжает движение против часовой стрелки;
- для `connected` и `error` постоянное кольцевое свечение также перенесено на ту же канавку;
- удалён большой нижний oval glow, который размывал свет по внешней тарелке и усиливал ощущение, что дуга стоит на наружной кромке;
- `disconnected` не менялся, потому что в этом состоянии активных дуг нет.

Проверка:
- `dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — No issues found;
- собрана ARM64 release APK, опубликована в `server-config/static-pages/downloads/app-release.apk` и `/opt/grani/granivpn-release-arm64.apk`.

Публичная ссылка:
- `https://api.granilink.com/downloads/app-release.apk?v=20260529-1415`;
- `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `content-length: 96107021`, `cache-control: no-store`, `cf-cache-status: BYPASS`;
- sha256: `b10f5c51d7ab5d65c69a8aace7f3707194a6ed1686f1d829309612659230f9aa`.

### 2026-05-29 17:00 MSK — финальная UI/state-machine итерация перед тестом

Повод:
- после просмотра preview APK нужно было довести не только кнопку, но и системное ощущение интерфейса GRANI;
- дуга в активных состояниях всё ещё частично шла не по рельсе канавки: на части окружности была меньше фактической канавки и визуально смещалась вправо;
- при отключении на LTE native VPN фактически останавливался, но UI мог уходить в `error` из-за backend/analytics tail после остановки туннеля;
- иконка приложения на launcher выглядела смещённой влево;
- в error-состоянии текст внутри кнопки не помещался;
- "Первичная настройка" и "Быстрое восстановление" должны быть не отдельными состояниями VPN, а тихим контекстом попытки подключения.

Изменено:
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - rail-геометрия активных дуг подогнана ближе к фактической канавке v3 PNG;
  - rail немного смещён влево и вниз, чтобы компенсировать визуальную асимметрию PNG-канавки;
  - `connecting` / `disconnecting` дуги стали заметнее, но остаются мягкими;
  - `connected` и `error` кольца слегка усилены, чтобы их было лучше видно в канавке;
  - bowl/center ещё немного высветлены кодовым overlay, чтобы меньше отличались от фона приложения;
  - error title/subtitle получили более узкое поле и меньший font-size, чтобы текст не вылезал за кнопку.
- `mobile-app/lib/widgets/button_connection.dart`:
  - error CTA внутри кнопки сокращён до `Retry` / `Повторить`;
  - subtitle error сокращён до `Check network` / `Проверьте сеть`.
- `mobile-app/lib/simple_vpn/simple_vpn_controller.dart`:
  - `disconnect()` больше не переводит UI в `error`, если native VPN уже успешно остановлен;
  - `stopSession` и логирование после native stop считаются best-effort;
  - это исправляет ложную ошибку UI при отключении на LTE/смене маршрута.
- launcher icon:
  - adaptive foreground и legacy mipmap PNG визуально отцентрованы по горизонтали;
  - временные backup-файлы `*.bak-20260529-center-icon` вынесены из `android/app/src/main/res` в `.asset-backups/20260529-center-icon`, иначе Gradle пытался считать их ресурсами и падал на merge resources.
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`:
  - заголовки стали state-driven: `Ready`, `Protected`, `Connection failed` и RU-аналоги;
  - `Первичная настройка` / `Быстрое восстановление` показываются только во время `connecting` как маленький тихий контекст попытки, а не как самостоятельный статус.
- `mobile-app/lib/screens/trial_unified_screen.dart`:
  - trial-тексты упрощены;
  - connection flow badge включён только при `connecting`, чтобы trial и premium shell говорили одним языком.
- `mobile-app/lib/widgets/profile/profile_ui_kit.dart`, `mobile-app/lib/screens/bottom_sheet_profile.dart`, `mobile-app/lib/theme.dart`:
  - меню профиля и selector/bottom-sheet элементы смягчены: меньше жёстких теней, больше светлого GRANI-material, мягче карточки и drawer edge.
- `mobile-app/lib/l10n/app_en.arb`, `mobile-app/lib/l10n/app_ru.arb`:
  - добавлены/обновлены тексты главного экрана и trial-состояний.

Архитектурная фиксация по "первичной настройке" и "быстрому восстановлению":
- это не новые VPN states и не отдельные ошибки;
- основной state machine остаётся: `disconnected`, `connecting`, `connected`, `disconnecting`, `error`;
- `Первичная настройка` / `Быстрое восстановление` — это `connectionFlowType` / context попытки внутри `connecting`;
- UI показывает этот контекст только как вторичный маркер, а не как главный заголовок.

Проверка:
- `flutter gen-l10n` — OK;
- `dart format` по изменённым Dart-файлам — OK;
- `flutter analyze ... --no-fatal-infos --no-fatal-warnings` по изменённым файлам — No issues found / только существующие info про `prefer_const_constructors` в профиле;
- собрана ARM64 release APK:
  - команда: `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release --target-platform android-arm64 --no-tree-shake-icons`;
  - результат Flutter: `build/app/outputs/flutter-apk/app-release.apk`, `96.7MB`;
  - опубликовано в `server-config/static-pages/downloads/app-release.apk`.

Публичная ссылка:
- `https://api.granilink.com/downloads/app-release.apk?v=20260529-1700`;
- `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `content-length: 96659057`, `cache-control: no-store`, `cf-cache-status: BYPASS`;
- sha256: `ad4d810030f484626709277b4be9cde3bee46b11da2561a496d73bc56e5d2fa0`.

Важно для теста:
- проверять 5 состояний кнопки: off, connecting, disconnecting, connected, error;
- отдельно проверить LTE disconnect: после отключения UI должен уходить в `disconnected`, а не в `error`;
- отдельно проверить launcher icon: G должен выглядеть визуально центрированным;
- если дуги всё ещё визуально идут не по канавке, следующий шаг — заменить кодовую дугу на отдельный PNG/Rive слой с точной маской рельсы.

### 2026-05-29 17:36 MSK — усиление дуг и подгонка рельсы канавки

Повод:
- по свежим скринам с устройства дуги всё ещё не были идеальны:
  - активный сегмент выглядел тонким;
  - glow был бледноватым;
  - местами дуга ощущалась не как свет в рельсе, а как слабый след рядом с канавкой;
  - тексты внутри центральной кнопки в некоторых состояниях выглядели близко к пределам диска.

Диагностика:
- проверены размеры PNG assets:
  - `grani_button_bowl_base_v3.png` имеет размер `1007x1024`, то есть не является квадратным;
  - при `BoxFit.contain` изображение внутри квадратного виджета получает горизонтальный padding, а кодовая дуга раньше рисовалась в идеальной квадратной системе координат;
  - из-за этого даже правильный радиус визуально мог расходиться с реальной канавкой.

Изменено в `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
- рабочая rail-геометрия дуги уменьшена с `0.652/0.646 * size` до `0.626/0.620 * size`, ближе к фактическому радиусу канавки PNG;
- сдвиг rail-центра скорректирован с `x -0.016 / y +0.008` до `x -0.010 / y +0.004`, чтобы не перетягивать дугу в сторону;
- `connecting` / `disconnecting` дуги усилены:
  - core-line стала толще;
  - mid-glow стал плотнее;
  - soft-glow стал заметнее, но без neon-эффекта;
  - secondary segment тоже усилен, чтобы две дуги читались как движение, а не как случайные пятна;
- `connected` и `error` кольца усилены по opacity/width, чтобы состояние не выглядело слишком бледным;
- общий active/error glow вокруг кнопки слегка усилен;
- текстовый блок внутри кнопки стал компактнее:
  - non-error title/subtitle уменьшены;
  - error title/subtitle ещё чуть ужаты;
  - ширина текстового поля снижена, чтобы длинные RU/EN строки не подходили к краям диска.

Проверка:
- `dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart lib/widgets/button_connection.dart --no-fatal-infos --no-fatal-warnings` — No issues found;
- собрана ARM64 release APK:
  - команда: `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release --target-platform android-arm64 --no-tree-shake-icons`;
  - результат Flutter: `build/app/outputs/flutter-apk/app-release.apk`, `96.7MB`;
  - опубликовано в `server-config/static-pages/downloads/app-release.apk`.

Публичная ссылка:
- `https://api.granilink.com/downloads/app-release.apk?v=20260529-1736`;
- `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `content-length: 96659057`, `cache-control: no-store`, `cf-cache-status: BYPASS`;
- sha256: `1592f60d5b88511035c71a1796dfaed942aab79e298b1417bd0e60c662df975a`.

Важно для следующего визуального теста:
- отдельно проверить `connecting`: дуга должна идти именно по канавке, не по внешней кромке тарелки;
- отдельно проверить `connected/error`: стало ли кольцо достаточно читаемым;
- если после этой итерации дуга всё ещё визуально “плавает”, следующий технически более надёжный путь — готовить дуги как отдельные PNG/Rive assets с той же геометрией, что и база кнопки, а не рисовать их математически поверх неидеально квадратного PNG.

### 2026-05-29 18:29 MSK — GRANI design-system pass: селекторы и профиль

Повод:
- после аудита стало понятно, что главный экран и кнопка уже выглядят сильнее, но профиль и часть системных элементов отстали от нового визуального языка;
- сервер и протокол на главном экране воспринимались как слабый footer, хотя это ключевые элементы управления VPN;
- профиль был слишком ослаблен: мало surface hierarchy, шапка аккаунта выглядела случайной, секции теряли каркас.

Изменено:
- `mobile-app/lib/theme.dart`:
  - добавлены GRANI surface tokens: `surfaceBase`, `surfaceSoft`, `surfaceRaised`, `surfaceControl`, `surfaceInset`, `surfaceStroke`, `warmAccent`, `errorCoral`;
  - добавлены единые shadow tokens: `surfaceSoftShadow`, `surfaceRaisedShadow`, `surfaceControlShadow`;
  - selector controls усилены: высота `30 -> 38`, радиус `14 -> 18`, gap `30 -> 22`, padding H `6 -> 10`;
  - gap кнопка -> selectors уменьшен `48 -> 38`, чтобы сервер/протокол были ближе к ядру экрана, а не ощущались нижним футером.
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`:
  - selector chips получили видимый soft border и stronger typography;
  - disabled opacity повышена `0.58 -> 0.74`, чтобы сервер/протокол не исчезали в подключенном/занятом состоянии.
- `mobile-app/lib/widgets/connection_block.dart`:
  - selector row в connecting/disconnecting теперь гасится до `0.72`, а не до `0.5`.
- `mobile-app/lib/widgets/server_selector_button.dart`:
  - legacy selector получил двухуровневую подпись `city/country` вместо шумной строки с IP;
  - текст стал плотнее и статуснее (`12.5`, `w600`);
  - добавлен border и общий `surfaceControlShadow`.
- `mobile-app/lib/widgets/protocol_selector_button.dart`:
  - иконка заменена с `settings` на `tune`;
  - текст и поверхность приведены к тем же правилам, что у server selector.
- `mobile-app/lib/widgets/profile/profile_ui_kit.dart`:
  - `GraniSectionCard` получил optional `emphasized` surface level;
  - обычные секции используют `surfaceSoftShadow`, акцентные — `surfaceRaisedShadow`;
  - строки профиля получили чуть более уверенную типографику и более спокойный chevron.
- `mobile-app/lib/screens/bottom_sheet_profile.dart`:
  - drawer padding увеличен `14 -> 16`;
  - профильная шапка теперь помещена в акцентную surface-card;
  - тёмный случайный аватар заменён на светлый GRANI-material circle с мягкой поверхностью;
  - subscription card также получила `emphasized: true`;
  - цель: вернуть профилю визуальный каркас, не возвращаясь к тяжёлым старым карточкам.

Проверка:
- `dart format` по изменённым Dart-файлам — OK;
- `flutter analyze` по проекту запускается, компиляционных ошибок от новых правок не показал, но общий проект всё ещё падает на существующих warning/info;
- собрана ARM64 release APK:
  - команда: `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release --target-platform android-arm64 --no-tree-shake-icons`;
  - результат Flutter: `build/app/outputs/flutter-apk/app-release.apk`, `96.7MB`;
  - опубликовано в `server-config/static-pages/downloads/app-release.apk` и `/opt/grani/granivpn-release-arm64.apk`.

Публичная ссылка:
- `https://api.granilink.com/downloads/app-release.apk?v=20260529-1829`;
- `curl -I` вернул `HTTP/2 200`, `content-type: application/vnd.android.package-archive`, `content-length: 96659057`, `cache-control: no-store`, `cf-cache-status: BYPASS`;
- sha256: `3089a4691ff7f876aa179602285254a920918b28c9f4e26dc423f5fc66f45f8c`.

Важно для следующего визуального теста:
- проверить главный экран в off/connecting/connected/error: стали ли сервер и протокол достаточно заметными, но не грубыми;
- проверить профиль: появилась ли структура между шапкой аккаунта, подпиской, аккаунтом, поддержкой и about;
- если профиль всё ещё выглядит как системные настройки Android, следующий шаг — redesign bottom sheets/profile sections по тем же surface tokens, но с более выраженными group surfaces.

### 2026-06-01 09:xx MSK — server selection/cancel investigation

Повод:
- после последней сборки пользователь смог подключиться только к Budapest;
- к остальным серверам подключение визуально не доходило до нормального состояния;
- кнопка отмены подключения не останавливала процесс: UI продолжал показывать connecting и не уходил в off.

Что проверено на сервере:
- backend/API контейнеры живы, `granivpn_api` после проверки перезапущен и снова `healthy`;
- `servers` в БД:
  - `1 HU-BUD-01 / Budapest / 45.12.132.94`;
  - `3 UK-LON-01 / London / 45.140.167.123`;
  - `4 IE-DUB-01 / Dublin / 194.4.51.125`;
- для всех трёх серверов `graniwg_enabled=true`, `wireguard_public_key` есть, `wireguard_port=51820`;
- `device_server_peers` для тестового устройства уже содержит prepared peers на всех трёх серверах:
  - HU: `10.0.0.13`;
  - UK: `10.0.0.5`;
  - IE: `10.0.0.3`;
- ручной backend verify показал, что peers на нодах есть; UK ранее даже имел свежий handshake/traffic.

Вывод по причине:
- проблема не выглядит как “сломаны UK/IE ноды”;
- по логам был важный симптом: для UK/IE backend выдавал config на `server_id=3/4`, но затем часть session/verify шла без нового `/config` и снова проверялась как `server_id=1`;
- наиболее вероятная причина: клиентский pipeline после отмены/переключения/быстрого восстановления мог терять выбранный сервер и возвращаться к первому серверу списка, то есть Budapest;
- отдельная причина по отмене: `SimpleVpnController.cancelConnect()` не инвалидировал текущий connect attempt и не переводил UI в `disconnected` сразу. Он ждал native/backend tail, поэтому пользователь видел, что отмена “не сработала”.

Изменено:
- `mobile-app/lib/simple_vpn/simple_vpn_controller.dart`:
  - добавлен отдельный cache key `simple_vpn_selected_server_id_v1`;
  - `loadOptions()` теперь восстанавливает выбранный сервер из cache, а не всегда падает на первый сервер списка;
  - `selectServer()` сохраняет выбранный сервер в cache;
  - после успешного config response выбранный сервер также сохраняется в cache;
  - `cancelConnect()` теперь:
    - сразу ставит `_connectCancelRequested=true`;
    - инкрементит `_connectAttemptId`, чтобы старая async-попытка стала устаревшей;
    - чистит active session/local connected state;
    - сразу переводит UI в `SimpleVpnState.disconnected`;
    - native disconnect и backend `stopSession(reason=user_cancel)` выполняет best-effort в фоне.
- `backend/api/simple_vpn.py`:
  - `session/start` теперь логирует `server_id` и `protocol`;
  - `session/verify` выбирает сервер в порядке:
    1. `request.server_id`;
    2. `server_id` из `_session_state`;
    3. `device.current_server_id`;
  - это нужно, чтобы verify не маскировался под Budapest, если request пришёл без server_id, но session start уже знал выбранный сервер.

Проверка:
- `python -m py_compile /app/api/simple_vpn.py` внутри `granivpn_api` — OK;
- backend контейнер `granivpn_api` перезапущен, статус `healthy`;
- `/opt/flutter/bin/dart format lib/simple_vpn/simple_vpn_controller.dart` — OK;
- `/opt/flutter/bin/flutter analyze` по всему проекту запускается, новых ошибок по `simple_vpn_controller.dart` нет, но общий проект по-прежнему возвращает `228 issues` из-за старых warning/info.

Важно:
- backend-часть уже активна после restart;
- клиентские правки `cancelConnect()` и persistent selected server попадут на устройство только после следующей APK-сборки;
- следующий тест после сборки:
  1. выбрать UK, подключиться, проверить что в backend logs `session start` и `node verify` идут с `server_id=3`;
  2. выбрать IE, подключиться, проверить `server_id=4`;
  3. во время connecting нажать кнопку отмены: UI должен сразу вернуться в off/disconnected, без ухода в error и без продолжения spinner.

### 2026-06-01 10:xx MSK — системная правка текстовых перекрытий Home/Trial/Button

Повод:
- на главном экране длинные progress/subtitle строки в RU перекрывали верх кнопки;
- та же проблема потенциально возможна в EN из-за отключённых ограничений `AdaptiveSubtitleText`;
- внутри круглой кнопки длинные подписи визуально выходили из безопасной зоны диска и выглядели как внешний случайный текст.

Причина:
- `mobile-app/lib/widgets/adaptive_text.dart` временно был оставлен в диагностическом режиме:
  - `AdaptiveSubtitleText` использовал `maxLines: null`;
  - `overflow: TextOverflow.visible`;
  - из-за этого любой длинный текст мог физически рисоваться поверх следующего слоя;
- Home и Trial позиционировали title/subtitle блок абсолютным `top`, не учитывая фактическую верхнюю границу блока кнопки на малых экранах;
- текст внутри `GraniConnectSurfaceButton` всегда пытался быть одной строкой, что плохо для длинных RU/EN subtitle.

Изменено:
- `mobile-app/lib/widgets/adaptive_text.dart`:
  - восстановлены системные ограничения контейнера;
  - `AdaptiveTitleText` и `AdaptiveSubtitleText` теперь уважают `maxLines`;
  - overflow теперь `ellipsis`, не `visible`;
  - включён `softWrap`, чтобы тексты жили внутри своего поля.
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`:
  - добавлена адаптивная геометрия title/subtitle блока;
  - блок статуса теперь вычисляет безопасную позицию относительно предполагаемого top кнопочного блока;
  - при риске пересечения статусный блок поднимается вверх, а не залезает на кнопку;
  - subtitle ограничен двумя строками для Home во всех состояниях RU/EN.
- `mobile-app/lib/screens/trial_unified_screen.dart`:
  - такая же безопасная геометрия применена для Trial;
  - правило действует и для initial/disconnected/connected, и для connecting/disconnecting;
  - subtitle также ограничен двумя строками, чтобы Trial не повторял проблему Home.
- `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`:
  - внутренняя текстовая зона диска расширена, но осталась внутри безопасной области;
  - title слегка уменьшен и остаётся в контролируемой области;
  - subtitle теперь может занимать до двух строк внутри кнопки;
  - длинные RU/EN подписи больше не должны становиться “широкой строкой” поверх диска.

Проверка:
- `/opt/flutter/bin/dart format` по 4 изменённым файлам — OK;
- `/opt/flutter/bin/flutter analyze lib/widgets/adaptive_text.dart lib/screens/main/clean_amnezia_home_screen.dart lib/screens/trial_unified_screen.dart lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart --no-fatal-infos --no-fatal-warnings` — `No issues found`;
- APK сборка НЕ запускалась по отдельному запрету пользователя.

Важно для следующего визуального теста:
- проверить RU/EN Home в состояниях `off/connecting/connected/disconnecting/error`;
- проверить Trial в тех же визуальных состояниях, особенно длинные connecting hints;
- если текст всё ещё кажется слишком близко к кнопке, следующий шаг — не ручной перенос строки, а уменьшение `titleBlockHeight/titleBlockTop` токенов или унификация copy на более короткий status language.

### 2026-06-01 10:xx MSK — правка свечения кнопки без фонового ореола

Повод:
- в состояниях `connecting`, `disconnecting`, `connected` и `error` вокруг круглой кнопки появлялось широкое светлое пятно, уходящее в фон экрана;
- визуально это выглядело как случайная засветка за пределами кнопки, особенно над селекторами и по бокам от диска.

Причина:
- в `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` был отдельный круглый `BoxShadow` почти на весь размер виджета (`0.98 * size`) с большим `blurRadius`;
- этот слой усиливал состояние, но рисовался как внешний фоновый glow, не привязанный к канавке/тарелке.

Изменено:
- широкий внешний `BoxShadow` активных состояний удалён;
- добавлен `_ContainedButtonHaloPainter`, который рисует тёплый radial halo только внутри внутренней окружности кнопки через `clipPath`, без выхода света в фон;
- слои `_GrooveGlowPainter` переработаны:
  - blur у широких слоёв уменьшен;
  - добавлен более плотный тонкий core-highlight;
  - active/error ring и rotating arcs теперь должны читаться как свет в канавке, а не как фоновой ореол.

Проверка:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart --no-fatal-infos --no-fatal-warnings` — No issues found;
- APK сборка НЕ запускалась по отдельному запрету пользователя.

Важно:
- визуально проверить после следующей APK-сборки состояния `connecting/disconnecting/connected/error`;
- ожидаемый результат: фон вокруг кнопки остаётся чистым, а премиальный тёплый свет концентрируется внутри диска и по канавке.

### 2026-06-01 10:xx MSK — добавлен свет на внешнюю чашу кнопки

Повод:
- после удаления фонового ореола свет стал аккуратнее, но внешняя часть кнопки выглядела чуть сухо;
- пользователь попросил добавить света на наружную часть самой кнопки, не возвращая засветку фона.

Изменено:
- в `_ContainedButtonHaloPainter` расширена clipping-маска с `0.415` до `0.475` радиуса кнопки, чтобы свет мог попасть на внешнюю чашу;
- добавлен `outerShellRect` с мягким radial glow по наружной зоне диска;
- добавлен `outerLipRect` с двумя stroke-слоями:
  - широкий тёплый размытый lip-glow;
  - тонкий акцентный highlight ближе к внутреннему краю внешней чаши;
- все новые слои остаются внутри clipped circle, то есть не должны снова светить в фон экрана.

Проверка:
- `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
- `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart --no-fatal-infos --no-fatal-warnings` — No issues found;
- APK сборка НЕ запускалась.

Важно:
- после следующей APK-сборки проверить, что внешний обод стал живее, но белый фон вокруг кнопки остался чистым.

### 2026-06-01 11:xx MSK — GRANI molecule для selector/control и меню

Повод:
- пользователь отметил, что кнопки выбора сервера и протокола сейчас наиболее близки по духу GRANI;
- принято решение сделать их базовой “молекулой” для подложек, кнопок меню, Grani Team/профильных action-поверхностей;
- APK сборку по-прежнему не запускать без отдельной команды.

Изменено:
- `mobile-app/lib/theme.dart`:
  - добавлен `surfaceControlBorder = #DEE6EE`;
  - добавлен `surfaceControlGradient` как мягкий top-left → bottom-right градиент `#FFFFFF / #F8FAFC / #F1F4F7`;
  - добавлен усиленный `surfaceControlShadowStrong`;
  - selector/control поднят до `166x42`, radius `20`, text size `12.5`, stroke стал плотнее;
  - `selectorButtonShadow` переведён на усиленную мягкую тень.
- `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`:
  - нижние сервер/протокол chips теперь используют `surfaceControlGradient`;
  - border opacity поднят до `0.96`;
  - gap icon → text вынесен в токен `selectorButtonIconGap`;
  - option rows внутри Home selector bottom sheet тоже переведены на GRANI molecule surface.
- `mobile-app/lib/widgets/server_selector_button.dart` и `mobile-app/lib/widgets/protocol_selector_button.dart`:
  - синхронизированы с новой selector-молекулой, чтобы старые кнопки в других экранах не выпадали из системы.
- `mobile-app/lib/widgets/profile/profile_ui_kit.dart`:
  - `GraniSectionCard` переведён на градиентную поверхность и общий border/shadow language;
  - профильные строки получили мягкую icon-подложку 30x30, чтобы меню перестало выглядеть как обычный список настроек;
  - radius профиля приведён к `22` как surface-action вариант молекулы.
- `mobile-app/lib/screens/bottom_sheet_profile.dart`:
  - кнопка выхода переведена на ту же surface-molecule с мягким красным border, вместо стандартного Flutter outlined button;
  - const-подсказки analyzer очищены.
- `mobile-app/lib/widgets/bottom_sheets/server_selector_bottom_sheet.dart` и `mobile-app/lib/widgets/bottom_sheets/protocol_selector_bottom_sheet.dart`:
  - старые жёсткие 2px/black shadows заменены на GRANI surface gradient/border/shadow;
  - list rows стали ближе к selector/control молекуле;
  - текст ограничен ellipsis, чтобы длинные страны/протоколы не ломали строку.

Проверка:
- `/opt/flutter/bin/dart format` по 8 изменённым файлам — OK;
- `/opt/flutter/bin/flutter analyze lib/theme.dart lib/screens/main/clean_amnezia_home_screen.dart lib/widgets/profile/profile_ui_kit.dart lib/screens/bottom_sheet_profile.dart lib/widgets/server_selector_button.dart lib/widgets/protocol_selector_button.dart lib/widgets/bottom_sheets/server_selector_bottom_sheet.dart lib/widgets/bottom_sheets/protocol_selector_bottom_sheet.dart --no-fatal-infos --no-fatal-warnings` — `No issues found`;
- APK сборка НЕ запускалась.

Важно для следующего визуального теста:
- проверить Home chips: высота стала 42, должны читаться заметнее, но не спорить с большой Connect-кнопкой;
- проверить Profile drawer: секции должны стать структурнее и материальнее, без возврата к тяжёлым карточкам;
- проверить server/protocol bottom sheets: rows должны выглядеть частью того же языка GRANI;
- если меню станет слишком плотным, следующий шаг — ослаблять icon-подложки, а не возвращать плоские строки.

### 2026-06-01 12:xx MSK — GRANI molecule распространена на устройства, подписки, split tunnel, язык, журнал и auth flow

Повод:
- пользователь уточнил, что меню уже движется в новый стиль, и попросил перевести остальные экраны на тот же язык:
  - `Мои устройства`;
  - `Управление подпиской`;
  - `Лимит девайсов`;
  - `Сплит туннелирование`;
  - `Выбор языка`;
  - `Журнал уведомлений`;
  - стартовый экран выбора способа авторизации;
  - email-auth экраны.

Важно:
- APK сборка НЕ запускалась, по отдельному запрету пользователя;
- задача была именно в унификации подложек/кнопок/карточек, без изменения бизнес-логики.

Изменено:
- `mobile-app/lib/theme.dart`:
  - добавлен общий helper `GraniTheme.graniSurfaceDecoration(...)`;
  - helper использует `surfaceControlGradient`, `surfaceControlBorder`, `surfaceControlShadowStrong`;
  - это базовая “GRANI molecule” для новых surface-карточек и soft controls.
- `mobile-app/lib/widgets/device_card.dart`:
  - карточки устройств переведены с плоского `cardBackground/buttonShadowStandard` на GRANI surface;
  - текущее устройство и подтверждение удаления получают мягкий border-акцент вместо тяжёлой заливки;
  - icon-подложка и кнопки удаления переведены на тот же surface language.
- `mobile-app/lib/screens/devices_screen.dart`:
  - блок лимита устройств оформлен как GRANI surface card;
  - retry-кнопка в ошибке получила surface-action стиль.
- `mobile-app/lib/screens/device_limit_screen.dart`:
  - blocking modal “Лимит устройств” переведён на общий градиентный фон и мягкую surface-обвязку;
  - индикатор лимита и skeleton-карточки переведены на GRANI surface.
- `mobile-app/lib/widgets/device_limit_sheet.dart`:
  - legacy/simple sheet больше не выглядит как стандартный Material list;
  - rows устройств и кнопки “Выйти/Отмена” переведены на GRANI molecule.
- `mobile-app/lib/widgets/split_tunnel/split_tunnel_ui_kit.dart`:
  - segmented controls и app rows переведены на surface gradient/border/shadow;
  - selected-состояние теперь читается через border/акцент, а не тяжёлую тёмную заливку.
- `mobile-app/lib/screens/split_tunnel_screen.dart`:
  - search field, domain hint, domain input, add-button, preset chips и domain chips получили soft surface;
  - экран split tunnel стал ближе к Home selector/protocol chips.
- `mobile-app/lib/widgets/bottom_sheets/language_selector_bottom_sheet.dart`:
  - language rows переведены со старых резких теней на GRANI molecule;
  - selected-состояние через мягкий зелёный border.
- `mobile-app/lib/screens/notification_journal_screen.dart`:
  - notification cards переведены на surface gradient/border/shadow;
  - иконка уведомления получила мягкую surface-подложку.
- `mobile-app/lib/screens/start_screen.dart`:
  - Google/email кнопки входа переведены на GRANI surface helper.
- `mobile-app/lib/screens/auth_email_screen.dart`:
  - email input получил surface gradient/border/shadow вместо плоской заливки.
- `mobile-app/lib/widgets/pin_code_input.dart`:
  - PIN slots переведены на surface gradient/border/shadow, чтобы email-code экран не выпадал из системы.
- `mobile-app/lib/screens/trial_ended_screen.dart`:
  - тарифные карточки и числовые бейджи переведены на GRANI surface.
- `mobile-app/lib/screens/payment_screen.dart`:
  - legacy payment card и тарифные rows переведены на GRANI surface.
- `mobile-app/lib/screens/payment_failed_screen.dart`:
  - bottom sheet ошибки оплаты получил общий светлый gradient/border.
- `mobile-app/lib/screens/subscription_activated_screen.dart`:
  - legacy card переведена с `cardShadowWithInset` на GRANI surface.
- `mobile-app/lib/screens/auth_register_success_screen.dart`:
  - фон экрана приведён к `startScreenBackgroundGradient`.

Проверка:
- `/opt/flutter/bin/dart format` по 17 изменённым файлам — OK;
- `/opt/flutter/bin/flutter analyze ... --no-fatal-infos --no-fatal-warnings` по тем же 17 файлам — exit code 0;
- analyzer показал только non-fatal warnings/infos по существующим legacy местам (`unused helper`, `prefer const`, `use_build_context_synchronously`), без blocking errors.

Что проверить визуально после следующей разрешённой APK-сборки:
- профиль/menu drawer: основные подложки уже новые, теперь важно сравнить с дочерними экранами;
- `Мои устройства` и `Лимит устройств`: карточки не должны стать слишком тяжёлыми;
- `Split tunnel`: выбранные режимы должны читаться без тёмной заливки;
- `Выбор языка` и `Журнал уведомлений`: rows должны выглядеть частью того же продукта;
- auth flow: кнопки входа, email input и PIN slots должны быть спокойными soft controls, а не старым Material/Flutter UI.

### 2026-06-01 13:xx MSK — миграция проекта на granilink.com как единственный домен

Повод:
- принято решение окончательно убрать старый домен из проекта и оставить только `granilink.com`;
- в DigitalOcean/Cloudflare у пользователя ещё видны старые DNS-зоны/записи, но код и runtime проекта должны больше не ссылаться на старый домен.

Изменено:
- во всех текстовых файлах `/opt/grani` заменён старый домен на `granilink.com`;
- затронуты project config/docs/scripts/defaults:
  - `server-config/*`, включая nginx/env/deploy docs;
  - backend defaults/scripts/config/tests;
  - mobile `app_config.dart` и связанные тесты;
  - admin-panel runtime/e2e/docs;
  - общие docs/reports/scripts;
- отдельно дочищен собранный `admin-panel/build/runtime-config.js`;
- отдельно дочищены текстовые логи в `/opt/grani/logs` и корневые диагностические log-файлы, чтобы поиск по проекту не находил старый домен;
- контейнеры `granivpn_api`, `granivpn_celery`, `granivpn_beat`, `granivpn_admin`, `granivpn_flower` пересозданы без nginx, чтобы обновить env без перезапуска 80/443.

Проверка:
- поиск по `/opt/grani` после чистки не находит старый домен (исключались только `.git`, Flutter build/cache, `node_modules` и проблемная broken symlink в third_party);
- env контейнеров `granivpn_api`, `granivpn_celery`, `granivpn_beat`, `granivpn_admin`, `granivpn_flower` больше не содержит старый домен;
- `docker ps` после recreate: API `healthy`, celery/beat/admin/flower запущены;
- `curl http://127.0.0.1:8010/health` — `status=healthy`;
- backend syntax check:
  - `python -m py_compile /app/init_db.py /app/core/config.py /app/application/services/vpn_operations_service.py /app/infrastructure/external/xray_manager.py` — OK;
- Flutter точечный analyze:
  - `flutter analyze lib/config/app_config.dart test/core/api/endpoint_router_test.dart test/protocols/xray/xray_config_test.dart --no-fatal-infos --no-fatal-warnings` — No issues found.

Важно:
- Docker nginx контейнер НЕ перезапускался: текущий running container держит старый mounted inode конфига, а новый project config уже очищен;
- перед будущим recreate/restart `granivpn_nginx` надо отдельно проверить/подготовить сертификаты для `api.granilink.com` и `granilink.com`, потому что в `/etc/letsencrypt/live` сейчас явно видны cert-директории для `admin.granilink.com` и `app.granilink.com`, а не для `api.granilink.com`/root;
- системные `/etc/nginx/sites-*` содержат старые legacy-конфиги вне проекта и сейчас не обслуживают 80/443 (порты заняты docker-proxy `granivpn_nginx`); если нужно полностью вычистить сервер вне проекта, это отдельный infra шаг после проверки сертификатов;
- DNS-зоны/записи в DigitalOcean и Cloudflare не менялись из Codex; старую зону/records `granivpn.ru` нужно удалить/отключить вручную в панелях после подтверждения, что `granilink.com` полностью обслуживает нужные endpoints.

### 2026-06-01 13:xx MSK — решение по DNS api.granilink.com

Решение пользователя:
- `api.granilink.com` больше не должен указывать на HU/Budapest API-proxy `45.12.132.94`;
- целевой origin для `api.granilink.com` — основной сервер `159.223.199.122`;
- в Cloudflare запись нужно поменять:
  - было: `api.granilink.com A 45.12.132.94 Proxied`;
  - должно быть: `api.granilink.com A 159.223.199.122 Proxied`.

Важно:
- это означает отказ от текущего HU API-proxy path для API-домена;
- VPN endpoints/ноды по-прежнему нельзя проксировать через Cloudflare, но `api.granilink.com` как HTTPS API можно держать `Proxied`;
- после изменения DNS нужно отдельно проверить `https://api.granilink.com/health` и `/downloads/app-release.apk`;
- перед restart/recreate `granivpn_nginx` всё ещё нужно проверить сертификаты/конфиг для `api.granilink.com` на origin.

### 2026-06-01 14:xx MSK — api.granilink.com переведён на основной origin и оживлён

Что сделал пользователь:
- в Cloudflare запись `api.granilink.com` изменена с `45.12.132.94` на `159.223.199.122`;
- Cloudflare SSL/TLS mode временно переключён с `Full (strict)` на `Full`, чтобы убрать `526 Invalid SSL certificate`.

Что сделано на сервере:
- проверено: после DNS-change Cloudflare доходил до origin, но в `Full (strict)` отдавал `526`;
- временно созданы cert-директории:
  - `/etc/letsencrypt/live/granilink.com`;
  - `/etc/letsencrypt/live/api.granilink.com`;
  - обе указывают symlink-ами на уже существующие cert files старого origin-сертификата;
  - это временный мост только для Cloudflare `Full`, не решение для `Full (strict)`;
- новый `/opt/grani/server-config/nginx/nginx.conf` проверен через одноразовый nginx container — syntax OK;
- `granivpn_nginx` пересоздан (`docker compose up -d --no-deps --force-recreate nginx`), чтобы подхватить новый project config вместо старого mounted inode.

Проверка:
- `https://api.granilink.com/health` через Cloudflare — `HTTP/2 200`, backend `status=healthy`;
- прямой origin check с `--resolve api.granilink.com:443:159.223.199.122 -k` — `HTTP/2 200`;
- активный `/etc/nginx/nginx.conf` внутри `granivpn_nginx` больше не содержит старый домен;
- `/downloads/app-release.apk?v=20260601-sslfix` через Cloudflare отдаёт правильный APK:
  - `content-type: application/vnd.android.package-archive`;
  - `content-length: 96659057`;
  - `cache-control: no-store`;
  - `cf-cache-status: BYPASS`;
- origin direct `/downloads/app-release.apk` также отдаёт правильный APK.

Осталось:
- Cloudflare всё ещё кэширует старый ответ на URL без query `https://api.granilink.com/downloads/app-release.apk` (`content-length: 12`, `cf-cache-status: HIT`);
- нужно в Cloudflare сделать Purge Cache для single URL:
  - `https://api.granilink.com/downloads/app-release.apk`;
- после purge повторить `curl -I https://api.granilink.com/downloads/app-release.apk`, ожидается `content-length: 96659057` и `cf-cache-status: BYPASS/MISS`;
- позже для возврата на `Full (strict)` нужен настоящий Cloudflare Origin Certificate или Let's Encrypt cert для `api.granilink.com`/`granilink.com`, а временные symlink cert-директории заменить нормальными сертификатами.

### 2026-06-01 14:xx MSK — Cloudflare purge завершён, api/downloads проверены

Что сделал пользователь:
- в Cloudflare выполнен Purge Cache для single URL:
  - `https://api.granilink.com/downloads/app-release.apk`.

Проверка после purge:
- `curl -I https://api.granilink.com/downloads/app-release.apk`:
  - `HTTP/2 200`;
  - `content-type: application/vnd.android.package-archive`;
  - `content-length: 96659057`;
  - `content-disposition: attachment`;
  - `cache-control: no-store`;
  - `cf-cache-status: BYPASS`;
- `curl https://api.granilink.com/health`:
  - `HTTP/2 200`;
  - body `status=healthy`;
  - database/servers/devices/celery_queues healthy;
- `docker ps`:
  - `granivpn_nginx` up после recreate;
  - `granivpn_api` healthy;
  - celery/beat/admin/flower/postgres/redis up.

Текущий DNS/SSL статус:
- `api.granilink.com` работает через Cloudflare `Proxied` на origin `159.223.199.122`;
- Cloudflare SSL mode сейчас `Full`, не `Full (strict)`;
- следующий hardening step: выпустить нормальный Cloudflare Origin Certificate или Let's Encrypt cert для `api.granilink.com`/`granilink.com`, заменить временные symlink cert-директории и вернуть Cloudflare на `Full (strict)`.

### 2026-06-01 14:xx MSK — api.granilink.com переведён на Full (strict)

Что сделано:
- выпущен нормальный Let's Encrypt certificate для `api.granilink.com` через webroot challenge;
- cert сохранён в `/etc/letsencrypt/live/api.granilink.com/`;
- renewal config создан: `/etc/letsencrypt/renewal/api.granilink.com.conf`;
- сертификат:
  - `subject=CN = api.granilink.com`;
  - `SAN: DNS:api.granilink.com`;
  - expires `2026-08-30`;
- `granivpn_nginx` проверен (`nginx -t`) и reload выполнен;
- пользователь вернул Cloudflare SSL/TLS mode на `Full (strict)`.

Проверка после возврата на strict:
- `https://api.granilink.com/health`:
  - `HTTP/2 200`;
  - body `status=healthy`;
  - database/servers/devices/celery_queues healthy;
- `https://api.granilink.com/downloads/app-release.apk`:
  - `HTTP/2 200`;
  - `content-type: application/vnd.android.package-archive`;
  - `content-length: 96659057`;
  - `cf-cache-status: BYPASS`;
- direct origin SNI check:
  - `openssl s_client -connect 159.223.199.122:443 -servername api.granilink.com`;
  - отдаёт сертификат `CN=api.granilink.com`, `SAN=api.granilink.com`.

Текущий статус:
- `api.granilink.com` работает через Cloudflare `Proxied` на `159.223.199.122`;
- Cloudflare SSL mode снова `Full (strict)`;
- 526 не воспроизводится;
- временный symlink backup `/etc/letsencrypt/live/api.granilink.com.tmp-symlink-` остался как след миграции, не используется активным nginx.

## Заметка 2026-06-01: инспекция верхней панели и меню
- Прочитан текущий код верхней панели: VpnTopBar использует padding 20x12, burger/share контейнеры 32x33, logo 37x48 через GraniTheme; share вызывает Share.share с Play Store URL.
- Прочитан текущий код профильного меню: кастомный showGeneralDialog слева, ширина 364/412 экрана, затемнение 45%, slide 300ms easeOutCubic; burger внутри меню 48x48 touch area, SVG 20x20; правки не вносились, APK не собирался.

## Заметка 2026-06-01: облегчение верхней панели GRANI
- Добавлен общий компонент mobile-app/lib/widgets/grani_top_icon_button.dart для верхних иконок с отдельными touch area и visible size.
- Home top bar: touch area burger/share оставлена 32x33, боковой padding увеличен 20*scaleX -> 24*scaleX, logo оставлен 37x48 без opacity.
- Burger SVG assets/images/figma/profile/menu_new.svg перерисован: canvas 32x24, линии около 26px, gap 9px, stroke 2.2, round caps, #182D3D opacity 0.88; visible size в home/drawer 26x20.
- Share на home top bar переведен на SVG assets/images/figma/share_icon.svg: visible 23x23, stroke 2.1, #182D3D opacity 0.86, более тонкие hollow nodes вместо тяжелого PNG/system-like вида.
- Drawer overlay облегчен: black opacity 0.45 -> 0.34; shadow opacity 0.16 -> 0.11, offset (16,0), blur 44, spread -24. Drawer touch area burger оставлена 48x48.
- Проверка: dart format по измененным Dart-файлам прошел; flutter analyze lib/widgets/vpn_top_bar.dart lib/widgets/grani_top_icon_button.dart lib/screens/bottom_sheet_profile.dart --no-fatal-infos --no-fatal-warnings: No issues found. APK не собирался. Реальный Android не проверен: adb на сервере недоступен.

## Заметка 2026-06-01: второй проход верхней панели
- По решению после мокапа бургер, его толщина и touch area больше не трогались.
- Проверены и применены следующие кандидаты: logo в home top bar увеличен на 8% (37x48 -> 39.96x51.84 в UI), share SVG заменен на более инженерный outline-вариант без залитых жирных точек и visible size уменьшен 23x23 -> 22x22, заголовок drawer profile усилен 18/w700 -> 19/w800.
- Проверка: dart format lib/widgets/vpn_top_bar.dart lib/screens/bottom_sheet_profile.dart прошел; flutter analyze по vpn_top_bar.dart, grani_top_icon_button.dart, bottom_sheet_profile.dart: No issues found. APK не собирался.

## Заметка 2026-06-01: menu/share в стиле GRANI molecule
- Проверен существующий surface system: GraniTheme.graniSurfaceDecoration(), surfaceControlGradient, surfaceControlBorder, surfaceSoftShadow, profile_ui_kit/selector surfaces.
- GraniTopIconButton теперь рисует мягкую GRANI molecule surface вокруг top icons через graniSurfaceDecoration(radiusPill, borderOpacity 0.72, surfaceSoftShadow), без новых цветов и без карточного вида.
- Home menu/share сохранили touch area 32x33; surfaceSize 32. Drawer menu сохранил touch area 48x48; surfaceSize 36. Иконки, лого и отступы не менялись в этом проходе.
- Проверка: dart format по grani_top_icon_button.dart, vpn_top_bar.dart, bottom_sheet_profile.dart прошел; flutter analyze по этим файлам: No issues found. APK не собирался.

## Заметка 2026-06-01: Privacy Policy 2.0
- Обновлена /opt/grani/server-config/static-pages/privacy.html: версия документа 2.0 от 2026-06-01, RU+EN локализация, серьезный premium-стиль GRANI, без эмодзи, с шапкой/футером, logo asset и GRANI molecule surface styling.
- Текст актуализирован под текущую архитектуру: email/Google login, Google Play subscriptions, device limit, selected server/protocol, VPN session metadata, API/backend/nginx/container diagnostics, no traffic content logging, Cloudflare/web API и отдельная VPN-инфраструктура.
- Добавлен static asset /opt/grani/server-config/static-pages/assets/logo_grani_new.png из mobile-app assets. В nginx для granilink.com добавлен location /assets/ с alias на static-pages/assets; nginx -t успешен, nginx reload выполнен.
- Проверка на origin успешна: curl --resolve granilink.com:443:159.223.199.122 https://granilink.com/privacy видит Privacy Policy / Версия 2.0; logo asset на origin отдается 200.
- Внешний https://granilink.com/privacy пока отвечает Tilda/DDOS-Guard 404, потому что публичный DNS granilink.com указывает на 176.57.66.222, не на DigitalOcean 159.223.199.122. Для фактической публикации по точному URL нужен DNS/Cloudflare/Tilda переключатель корневого домена или публикация этой HTML-версии на стороне Tilda.

## Заметка 2026-06-01: публикация Privacy Policy на granilink.com
- После смены DNS в Cloudflare публичный granilink.com начал идти через Cloudflare на DigitalOcean, но Cloudflare отдавал 526 из-за origin certificate mismatch: nginx для granilink.com использовал symlink на cert granivpn.ru.
- Выпущен новый Let\s Encrypt сертификат cert-name granilink-com-20260601 для granilink.com и www.granilink.com, срок до 2026-08-30. Nginx granilink.com server block переключен на /etc/letsencrypt/live/granilink-com-20260601/fullchain.pem и privkey.pem.
- Из-за bind-mount файла nginx.conf потребовался docker compose restart nginx, чтобы контейнер увидел новый inode конфигурации; после рестарта origin cert subject=granilink.com SAN=granilink.com,www.granilink.com.
- Проверка публично через Cloudflare успешна: https://granilink.com/privacy HTTP/2 200, https://www.granilink.com/privacy HTTP/2 200, /assets/logo_grani_new.png HTTP/2 200; страница содержит Privacy Policy / Версия 2.0 / EN Version 2.0.

## Заметка 2026-06-01: Google tag для GA4/Search Console
- По просьбе пользователя установлен Google tag `G-PEVT8SSG8C`.
- Изменены файлы:
  - `/opt/grani/server-config/static-pages/privacy.html`;
  - `/opt/grani/server-config/static-pages/index.html` (новая корневая HTML-страница GRANI VPN);
  - `/opt/grani/admin-panel/build/index.html`;
  - `/opt/grani/admin-panel/public/index.html` (чтобы тег сохранялся при будущей сборке админки);
  - `/opt/grani/server-config/nginx/nginx.conf`.
- В nginx для `granilink.com` exact root `/` переключён с plain text `GraniVPN API` на static `/var/www/granivpn/static-pages/index.html`; первый вариант с `alias` дал 500 (`index.htmlindex.html`), исправлено на `root + try_files /index.html`.
- `nginx -t` успешен, `granivpn_nginx` reload выполнен.
- Проверка публично через Cloudflare:
  - `https://granilink.com/` — HTTP/2 200, `content-type: text/html; charset=utf-8`, содержит `googletagmanager.com/gtag/js` и `G-PEVT8SSG8C`;
  - `https://www.granilink.com/` — HTTP/2 200, тег есть;
  - `https://granilink.com/privacy` — тег есть;
  - `https://www.granilink.com/privacy` — тег есть;
  - `https://admin.granilink.com/` — тег есть.
- Важно: `https://app.granilink.com/` сейчас проксируется на Netlify (`gleaming-brioche...`) и его HTML не содержит `G-PEVT8SSG8C`; это не файл текущего DO static/admin проекта. Если GA4 должен быть и на app-сайте, нужно править исходник/деплой Netlify или менять proxy target.

## Заметка 2026-06-01: Google OAuth branding privacy-policy fallback
- В Google Cloud OAuth Branding текущая версия уже указывает `https://granilink.com/privacy`, но опубликованная версия ещё показывала `https://granilink.com/privacy-policy`.
- Чтобы старая published branding не вела в 404, в `server-config/nginx/nginx.conf` добавлены редиректы:
  - `/privacy-policy` -> `/privacy`;
  - `/privacy-policy/` -> `/privacy`.
- `nginx -t` успешен, `granivpn_nginx` reload выполнен.
- Проверка:
  - `https://granilink.com/privacy-policy` — HTTP/2 301, `location: https://granilink.com/privacy`;
  - `https://granilink.com/privacy` — HTTP/2 200.
- Следующий ручной шаг в Google Cloud: открыть Branding `View issues`, пройти verification/publish для Current branding, чтобы опубликованная версия тоже показывала `/privacy`.

## Заметка 2026-06-01: Privacy Policy 2.0 внутри Flutter-приложения
- По задаче пользователя обновлена политика конфиденциальности в приложении на базе текста живой страницы `https://granilink.com/privacy` (версия 2.0, обновлено 2026-06-01).
- Удален старый устаревший текст политики из:
  - `mobile-app/lib/widgets/privacy_policy_bottom_sheet.dart`;
  - `mobile-app/lib/screens/privacy_policy_screen.dart`.
- Добавлен общий нативный документ:
  - `mobile-app/lib/widgets/privacy_policy_document.dart`;
  - используется и в bottom sheet на старте/авторизации, и в маршруте `/privacy`.
- Локализация сделана внутри документа по текущему `Localizations.localeOf(context)`: RU и EN версии содержат полный актуальный текст политики, включая:
  - email/Google login;
  - Google Play subscriptions;
  - device limit;
  - selected server/protocol и VPN session metadata;
  - backend/API/nginx/container diagnostics;
  - no traffic content logging;
  - Cloudflare/web API и отдельную VPN-инфраструктуру;
  - сроки хранения, права пользователя, cookies, international transfers, document version.
- Визуальная стилизация переведена на GRANI molecule:
  - `GraniTheme.graniSurfaceDecoration`;
  - `surfaceControlGradient`;
  - мягкие surface cards/pills;
  - warm accent bullets;
  - без эмодзи и старого “простыня текста” вида.
- Проверка:
  - `/opt/flutter/bin/dart format lib/widgets/privacy_policy_document.dart lib/widgets/privacy_policy_bottom_sheet.dart lib/screens/privacy_policy_screen.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/widgets/privacy_policy_document.dart lib/widgets/privacy_policy_bottom_sheet.dart lib/screens/privacy_policy_screen.dart --no-fatal-infos --no-fatal-warnings` — `No issues found`;
  - APK не собирался.

## Заметка 2026-06-01 19:23 MSK: release-сборки AAB и APK
- По прямой команде пользователя собраны две release-версии мобильного приложения:
  - Google Play Android App Bundle: `/opt/grani/mobile-app/build/app/outputs/bundle/release/app-release.aab`;
  - release APK: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`.
- Текущая версия из `pubspec.yaml`: `1.0.4+21`.
- Release signing использован из `/opt/grani/mobile-app/android/key.properties` и keystore `/opt/grani/mobile-app/android/granivpn-release-key.jks`.
- ABI остается `arm64-v8a`.
- Команды:
  - `/opt/flutter/bin/flutter build appbundle --release` — успешно, `app-release.aab` около 77.1 MB;
  - `/opt/flutter/bin/flutter build apk --release` — успешно, `app-release.apk` около 96.1 MB.
- Артефакты опубликованы в `/opt/grani/server-config/static-pages/downloads/`:
  - `app-release.apk`;
  - `app-release.aab`.
- Проверка SHA-256:
  - APK: `b4c67d5d6d010324455707c9268b18bcfb3677f958549ca06b772c889ccf67ca`;
  - AAB: `d6ba8844cf3bbfa7611824c44ea87d38b2dd496da0bd8909d5208c70f877c201`.
- Публичная проверка загрузки:
  - `https://api.granilink.com/downloads/app-release.apk` — HTTP/2 200, `content-type: application/vnd.android.package-archive`, `content-length: 96106975`, `content-disposition: attachment`, `cf-cache-status: BYPASS`;
  - `https://api.granilink.com/downloads/app-release.aab` — HTTP/2 200, `content-type: application/octet-stream`, `content-length: 77055319`, `content-disposition: attachment`.

## Заметка 2026-06-02: воздух вокруг top menu/share GRANI molecule
- По просьбе пользователя проверено влияние увеличения мягкой подложки под верхними иконками menu/share.
- Вывод: правка точечная. Компонент `GraniTopIconButton` используется для верхних menu/share и drawer menu; домашняя верхняя панель задает собственные размеры через параметры `VpnTopBar`.
- Изменен только `mobile-app/lib/widgets/vpn_top_bar.dart`:
  - горизонтальный padding top bar `24 * scaleX` -> `20 * scaleX`, чтобы центры иконок остались примерно на прежних местах;
  - touch/layout area menu/share `32x33` -> `40x40`;
  - visible GRANI molecule surface `32` -> `38`;
  - размеры самих SVG-иконок не менялись (`menu 26x20`, `share 22x22`), чтобы появился именно воздух вокруг иконок.
- Это не меняет все иконки проекта и не затрагивает сервер/протокол selectors, profile rows, bottom sheets и прочие surfaces.
- Проверка:
  - `/opt/flutter/bin/dart format lib/widgets/vpn_top_bar.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/widgets/vpn_top_bar.dart lib/widgets/grani_top_icon_button.dart --no-fatal-infos --no-fatal-warnings` — `No issues found`;
  - APK не собирался.

## Заметка 2026-06-01 20:55 MSK: Google Play build versionCode 22

- По команде пользователя поднят Google Play build code:
  - `mobile-app/pubspec.yaml`: `version: 1.0.4+21` -> `version: 1.0.4+22`;
  - `mobile-app/lib/config/app_config.dart`: fallback `buildNumber` обновлён `21` -> `22`, чтобы fallback-версия совпадала с `pubspec` до инициализации `PackageInfo`.
- Проверка:
  - `/opt/flutter/bin/dart format lib/config/app_config.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/config/app_config.dart --no-fatal-infos --no-fatal-warnings` — No issues found;
  - release manifest после сборки содержит `android:versionCode="22"` и `android:versionName="1.0.4"`.
- Собран новый Google Play Android App Bundle:
  - команда: `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build appbundle --release`;
  - результат: `mobile-app/build/app/outputs/bundle/release/app-release.aab`;
  - размер Flutter artifact: `77.1MB`.
- AAB опубликован:
  - `server-config/static-pages/downloads/app-release.aab`;
  - публичная ссылка: `https://api.granilink.com/downloads/app-release.aab?v=20260601-2054`;
  - `curl -I` вернул `HTTP/2 200`, `content-type: application/octet-stream`, `content-length: 77055340`, `content-disposition: attachment`.
- SHA-256:
  - AAB: `3728c26b74ce11a9ec79c0408f0dd9562b935b7ce73ffe4cfc66188d4b08133b`.
- Подпись:
  - `jarsigner -verify` вернул `jar verified`;
  - сертификат истекает `2053-06-01`.
- APK в этом проходе не пересобирался, так как задача была именно подготовить Google Play AAB с versionCode 22.

## Заметка 2026-06-02: локализация bottom sheet выбора протокола

- Исправлена незавершенная локализация экрана/шторки выбора протокола в `mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`:
  - заголовок bottom sheet больше не hardcoded `Протокол`, используется `context.l10n.protocolSheetTitle`;
  - subtitle строки GRANIwg больше не hardcoded `Защищенный WireGuard`, используется `context.l10n.protocolSheetGraniWgSubtitle`.
- Добавлены ключи локализации:
  - `mobile-app/lib/l10n/app_en.arb`: `protocolSheetTitle = Protocol`, `protocolSheetGraniWgSubtitle = Protected WireGuard`;
  - `mobile-app/lib/l10n/app_ru.arb`: `protocolSheetTitle = Протокол`, `protocolSheetGraniWgSubtitle = Защищенный WireGuard`.
- Выполнено `/opt/flutter/bin/flutter gen-l10n`; обновлены `app_localizations.dart`, `app_localizations_en.dart`, `app_localizations_ru.dart`.
- Проверки:
  - `/opt/flutter/bin/dart format lib/screens/main/clean_amnezia_home_screen.dart lib/l10n/app_localizations.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_ru.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/screens/main/clean_amnezia_home_screen.dart --no-fatal-infos --no-fatal-warnings` — No issues found.
- APK не собирался.

## Заметка 2026-06-02: единый GRANI дизайн для email-писем

- По задаче пользователя пересмотрена верстка всех существующих email-писем проекта в соответствии с новым дизайн-кодом GRANI.
- Найденные активные письма:
  - код подтверждения входа;
  - предупреждение о скором окончании подписки;
  - окончание подписки;
  - окончание trial;
  - ручная/системная активация подписки;
  - успешная оплата;
  - отзыв/отмена подписки после refund;
  - неуспешный платеж.
- Основной файл шаблонов:
  - `backend/services/email_service.py`.
- Legacy-файл:
  - `backend/infrastructure/external/email_service.py` теперь является compatibility wrapper на `services.email_service`, чтобы старые импорты не возвращали старый визуальный шаблон.
- Что изменено в email-дизайне:
  - вместо старой тяжелой gradient header-плашки введен спокойный GRANI email shell;
  - используется светлый фон `#F7F9FA`, белая мягкая карточка, GRANI molecule-подложка, status badge, detail card и темная CTA-кнопка;
  - коды подтверждения больше не выглядят как выделенный синий текст, а выводятся в мягком premium code block;
  - для статусов используются разные GRANI-состояния: `info`, `success`, `warning`, `danger`;
  - все основные письма имеют RU/EN варианты через текущий параметр `language`;
  - динамические значения экранируются через `html.escape`.
- Добавлена функция демонстрации:
  - `create_email_preview_document(language="ru")`;
  - локальная копия preview: `email-preview.html`;
  - серверная копия: `/opt/grani/server-config/static-pages/email-preview.html`;
  - временная download-ссылка: `https://api.granilink.com/downloads/email-preview.html`.
- Проверки:
  - локально: `python -m py_compile .\email_service.py .\infrastructure_email_service.py` — OK;
  - сервер: `python3 -m py_compile services/email_service.py infrastructure/external/email_service.py aws_ses_service.py services/notification_service.py api/auth.py` — OK;
  - серверная генерация RU/EN preview — OK, контрольные типы писем присутствуют;
  - поиск по backend подтвердил, что активные email-вызовы идут через `services/email_service.py`, а `aws_ses_service.py` остается транспортом.
- APK не собирался.

### Уточнение 2026-06-02 по email preview

- По визуальной проверке preview исправлены два спорных элемента:
  - в верхнем GRANI badge удалена маленькая оранжевая/красная точка, потому что рядом с разряженным `GRANI` она давала визуальный дисбаланс;
  - удален большой пустой декоративный блок под логотипом. Изначально он задумывался как мягкая GRANI surface/molecule-зона, но в письме читался как пустой баннер или незагруженный контент.
- Preview пересобран:
  - локально обновлен `email-preview.html`;
  - серверно обновлены `/opt/grani/server-config/static-pages/email-preview.html` и `/opt/grani/server-config/static-pages/downloads/email-preview.html`.
- Проверки:
  - `python -m py_compile .\email_service.py` — OK;
  - `python3 -m py_compile services/email_service.py infrastructure/external/email_service.py aws_ses_service.py services/notification_service.py api/auth.py` — OK;
  - генерация preview подтвердила: точка удалена, `height:96px` декоративный блок удален.

### Проверка 2026-06-02: локализация email-писем

- Проверена локализация email-шаблонов в `backend/services/email_service.py`:
  - RU и EN варианты генерируются для verification, subscription warning, subscription expired, trial ended, subscription activated, payment success, subscription revoked/refund, payment failed;
  - RU subject/text/html содержат русские строки;
  - EN subject/text/html не содержат кириллицы;
  - `backend/api/auth.py` передает `language` в `send_verification_email`;
  - `backend/services/notification_service.py` берет язык из `user.preferred_language` через `_lang(user)`;
  - `backend/aws_ses_service.py` передает `language` в `create_verification_email_text/html`.
- Для визуального сравнения добавлен EN preview:
  - локально: `email-preview-en.html`;
  - серверно: `/opt/grani/server-config/static-pages/email-preview-en.html`;
  - download: `https://api.granilink.com/downloads/email-preview-en.html`.

## Заметка 2026-06-02: геометрия контента внутри кнопки подключения

- По визуальной правке пользователя скорректирована посадка power/error icon, title и subtitle внутри большой кнопки подключения.
- Изменен только `mobile-app/lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart`.
- Причина: после перехода на PNG-ассеты чаши/центрального диска старый сдвиг контентного блока вверх (`-size * 0.018`) стал выглядеть как легкий рассинхрон с центром диска.
- Правка:
  - общий vertical offset контента с subtitle уменьшен до `-size * 0.006`;
  - расстояние icon -> title уменьшено с `size * 0.058` до `size * 0.050`;
  - бизнес-логика, state machine, дуги и ассеты не менялись.
- Проверка:
  - `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart --no-fatal-infos --no-fatal-warnings` — No issues found.
- APK не собирался.

## Заметка 2026-06-09: подготовка Hetzner-ноды и SSH-доступа

- Пользователь начал покупку нового сервера Hetzner для расширения VPN-инфраструктуры.
- Рекомендованный первый тестовый вариант:
  - Hetzner Cloud CX23;
  - x86 AMD;
  - локация Falkenstein или другая EU-локация по доступности;
  - Ubuntu LTS, предпочтительно 24.04 LTS, если доступна в выпадающем списке;
  - Public IPv4 + IPv6 включены;
  - без volume/backups на первом тесте;
  - имя сервера можно использовать `grani-de-fsn1-01`.
- SSH-ключ для Hetzner:
  - публичный ключ локально: `C:\Users\railt\.ssh\do_login_ed25519.pub`;
  - fingerprint/label: `do-login-20260325`;
  - в Hetzner Console нужно нажать `Add SSH key` и вставить публичный ключ;
  - приватный ключ пользователю передавать не нужно и нельзя, он остается локально.
- После создания сервера пользователь должен передать только IPv4, имя и локацию. Подключение выполняется командой вида:
  - `ssh -i C:\Users\railt\.ssh\do_login_ed25519 root@<HETZNER_IPV4>`.
- Проверено текущее состояние backend:
  - активная выдача серверов для мобильного приложения идет через `/simple-vpn/servers`;
  - фильтр backend: `Server.is_active == true` и `Server.graniwg_enabled == true`;
  - значит новую Hetzner-ноду для текущего приложения надо сначала вводить как GRANIwg/AmneziaWG-ноду;
  - Xray/VLESS можно добавлять вторым этапом, но текущий основной рабочий путь приложения — GRANIwg.
- Текущее состояние серверов в БД на момент проверки:
  - всего серверов: 4;
  - активных: 1;
  - единственная активная нода: `SE-STO-01`, IP `13.140.9.211`, протокол `graniwg`;
  - остальные серверы неактивны и в текущий mobile flow не попадают.
- Старые скрипты для серверов существуют, но часть из них историческая и захардкожена под старые IP/парольные подключения (`create_server_direct.py`, `setup_vpn_server.py`, `check_and_fix_server.py`). Для Hetzner лучше не копировать их слепо, а пройти новую последовательность:
  1. проверить SSH-доступ по ключу;
  2. проверить OS/kernel/network/IPv4/IPv6;
  3. установить и настроить GRANIwg/AmneziaWG;
  4. сгенерировать server WireGuard keys;
  5. включить forwarding/NAT/firewall;
  6. добавить запись в `servers` с `provider=Hetzner`, `provider_region`, `ssh_key_path` или управляемым ключевым доступом, `wireguard_public_key`, `wireguard_port`, `graniwg_enabled=true`, `supported_protocols=["graniwg"]`, `is_active=true`;
  7. проверить, что `/simple-vpn/servers` возвращает новую ноду;
  8. сделать live-тест подключения с телефона.
- APK/AAB не собирались.

### Уточнение 2026-06-02: горизонтальная оптическая центровка кнопки

- Проверена горизонтальная центровка контента внутри большой кнопки подключения.
- По коду content block был математически центрирован в квадрате виджета, но PNG-ассеты имеют альфа-bbox со смещением влево:
  - `grani_button_bowl_base_v3.png`: bbox center примерно `dx=-14.5` px в исходнике;
  - `grani_button_center_source_v3.png`: bbox center примерно `dx=-9.0` px в исходнике.
- После масштабирования на экран это дает около 3 px визуального смещения, из-за чего power icon/title/subtitle выглядели чуть правее фактического центра диска.
- Добавлен оптический X-offset контента:
  - `contentOffsetX = -size * 0.009`;
  - применяется только к внутреннему контенту кнопки (`Transform.translate`), ассеты, дуги и state machine не менялись.
- Проверка:
  - `/opt/flutter/bin/dart format lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart` — OK;
  - `/opt/flutter/bin/flutter analyze lib/features/vpn/presentation/widgets/grani_connect_surface_button.dart --no-fatal-infos --no-fatal-warnings` — No issues found.
- APK не собирался.
- [2026-06-09] Germany Hetzner node fully integrated into GRANI backend as active GRANIwg server. Node DE-FSN-01, server_id=6, IP 167.233.66.144, provider Hetzner, region fsn1/Falkenstein, plan CX23 (2 vCPU, 4 GB RAM, 40 GB disk). Existing personal Amnezia Docker container amnezia-awg2 was left untouched on UDP 39059; GRANI uses a separate host interface wg0 on UDP 51820.
- [2026-06-09] Germany host setup: copied proven Stockholm scripts /root/setup-amneziawg-grani.sh and /root/setup_grani_awg_node.sh; installed AmneziaWG via PPA packages for Ubuntu 24.04 (amneziawg, amneziawg-dkms, amneziawg-tools); created /usr/local/bin/wg and /usr/local/bin/wg-quick wrappers; created /etc/amnezia/amneziawg/wg0.conf; AWG params Jc=4,Jmin=5,Jmax=60; public key qS8pI1qab0BWSJLjdKDhuzfIy1rbwq5hq4jGaqeewAc=. Private key was saved only into node config/backend DB as operational secret and not written to context.
- [2026-06-09] Germany systemd fixed: after initial manual awg-quick up wg0, switched to systemctl start awg-quick@wg0; final state enabled and active; wg show wg0 returns running interface on port 51820. UDP 51820 and personal Amnezia UDP 39059 both listen simultaneously.
- [2026-06-09] Backend DB: added/updated servers row id=6 with is_active=true, status=online, graniwg_enabled=true, supported_protocols=["graniwg"], wireguard_config_path=/etc/amnezia/amneziawg/wg0.conf, wireguard_interface=wg0, SSH key content copied from active Stockholm management key. Active GRANIwg servers are now SE id=5 and DE id=6. SIMPLE_VPN_SERVER_ID was not changed; default remains Stockholm id=5.
- [2026-06-09] Backend verification for Germany: RemoteVPNManager.get_wireguard_status(server_id=6) returned running; config readable (config_len=542); next available peer IP 10.0.0.2; /api/health returned healthy with total_servers=2, healthy=2; granivpn_api container healthy; python -m py_compile /app/api/simple_vpn.py /app/api/admin_metrics.py /app/api/admin.py /app/infrastructure/external/remote_vpn_manager.py OK.
- [2026-06-09] Mobile localization prep for next APK/AAB: /opt/grani/mobile-app/lib/screens/main/clean_amnezia_home_screen.dart now maps Falkenstein/Фалькенштайн for RU/EN server display. Checks: /opt/flutter/bin/dart format lib/screens/main/clean_amnezia_home_screen.dart OK; /opt/flutter/bin/flutter analyze lib/screens/main/clean_amnezia_home_screen.dart --no-fatal-infos --no-fatal-warnings OK, no issues. APK/AAB не собирались.
- [2026-06-09] Published AAB download link for Play upload: copied /opt/grani/mobile-app/build/app/outputs/bundle/release/app-release.aab to /opt/grani/server-config/static-pages/downloads/grani-vpn-20260609-v24.aab with www-data ownership; checksum file grani-vpn-20260609-v24.aab.sha256 created. Public URL verified HTTP 200: https://api.granilink.com/downloads/grani-vpn-20260609-v24.aab (content-length 77089146, content-disposition attachment). app.granilink.com and granilink.com downloads paths return 404; use api.granilink.com for this artifact.
- [2026-06-09] DE-FSN-01 dataplane investigation after user reported Speedtest stuck with only tiny RX on Android notification. Diagnosis: not a Hetzner SSH-key/server-login issue. Same VPS personal Amnezia container on UDP 39059 works well, while GRANI host-level `wg0` on UDP 51820 showed stale handshakes, very small RX, and `wg0` RX errors under the minimal AmneziaWG profile. Active live test account was `rail.tamaew@gmail.com` on device id 225 / peer `10.0.0.3`; `railcuber@gmail.com` peer `10.0.0.2` was suspended due `subscription_expired`.
- [2026-06-09] Applied backend-only DE-FSN-01 GRANIwg profile fix. Updated server #6 `graniwg_obfuscation_key` from minimal `{"Jc":4,"Jmin":5,"Jmax":60}` to full AmneziaWG params matching the known-working Amnezia profile shape: `Jc=5,Jmin=10,Jmax=50,S1=138,S2=20,S3=35,S4=13,H1=1065396326-1762624561,H2=1938780048-1988422668,H3=2118021394-2124378345,H4=2132846382-2134177661`. Updated `/etc/amnezia/amneziawg/wg0.conf` on DE and restarted only `awg-quick@wg0`; personal Docker Amnezia container on UDP 39059 was not touched.
- [2026-06-09] Forced DE mobile profile refresh by tagging active DE `device_server_peers.config_revision` with `awgfull-v1-20260609`. Verified generated mobile config for active DE device contains full `S1-S4/H1-H4` parameters, endpoint `167.233.66.144:51820`, and `PersistentKeepalive=25`. `awg show wg0` now reports `jc=5,jmin=10,jmax=50,s1-s4,h1-h4`; `ip -s link show wg0` counters reset to zero after restart. Next test: user must disconnect/reconnect to DE so app fetches new config revision; then monitor `wg0` RX/TX/errors and client logs.
- [2026-06-09] Follow-up DE test for `railcuber@gmail.com`: full-AWG profile removed `wg0` RX errors, but DE still showed very small RX and stale handshake while Stockholm (#5) on the same user/device verified traffic normally. This rules out phone/account as primary cause and points to DE GRANIwg host-level port/path/profile. Changed DE-FSN-01 GRANIwg ListenPort and DB `wireguard_port` from default UDP 51820 to UDP 39060, next to the known-working personal Amnezia Docker port 39059. `awg-quick@wg0` restarted; `ss -lunp` shows UDP 39059 (Docker Amnezia) and UDP 39060 (GRANIwg) listening without conflict. Tagged DE peer revisions with `port39060-v1-20260609`; generated mobile config now uses `Endpoint = 167.233.66.144:39060`.
- [2026-06-09] `railcuber@gmail.com` test access note: latest Google Play test subscription #47 expired during the DE investigation window (end ~09:23 UTC), which caused backend `access_check_failed` and suspended the DE peer again. For clean server testing, subscription #47 was temporarily extended by 1 hour to `2026-06-09T10:33:24Z`, and active GRANIwg peers for this user were unsuspended. This is a diagnostic extension, not an APK/build change. Next clean test: fully disconnect, reopen app, select Falkenstein/Germany, reconnect, confirm the phone fetches the `port39060-v1-20260609` profile, then check Speedtest and server counters.

## Заметка 2026-06-09: Hetzner LTE dataplane и сравнение со старыми нодами

- Важное пользовательское наблюдение: на новом Hetzner-сервере личная Amnezia по Wi-Fi работает, а по LTE ломается примерно так же, как GRANI. Это резко снижает вероятность причины в мобильном UI/кнопке/SSH-ключе и переводит фокус на LTE dataplane path: MTU/UDP fragmentation, UDP shaping оператора, маршрут LTE -> Hetzner или host-level AWG runtime.
- Старые ноды, которые перестали работать из-за закрытия сервиса, проверены как historical baseline:
  - `HU-BUD-01` `45.12.132.94`, `UK-LON-01` `45.140.167.123`, `IE-DUB-01` `194.4.51.125`;
  - все три сейчас недоступны по SSH (`timed out`), поэтому live runtime comparison невозможен;
  - по БД и скриптам они относятся к старому classic WireGuard path: `/etc/wireguard/wg0.conf`, UDP `51820`, `setup-wireguard-server.sh`.
- Новые Hetzner-ноды относятся к другому runtime class:
  - `DE-FSN-01` и `FI-HEL-01`: Ubuntu 24.04.4, kernel `6.8.0-117-generic`, AmneziaWG DKMS module `1.0.20251009`, `/etc/amnezia/amneziawg/wg0.conf`, публичный IPv4 как `/32` через `172.31.1.1`;
  - рабочий `SE-STO-01`: Ubuntu 26.04, kernel `7.0.0-14-generic`, AmneziaWG module `1.0.0`, обычный `/24` маршрут, `/etc/amnezia/amneziawg/wg0.conf`.
- На всех GRANIwg клиентах до этого момента backend жестко отдавал `MTU = 1420`. С учетом симптома "handshake/мелкие пакеты есть, Speedtest/полезный поток умирает" это главный быстрый server/backend-only тест для LTE.
- Backend-only MTU test применен только к `FI-HEL-01`:
  - в `backend/infrastructure/external/wireguard_manager.py` и legacy `backend/services/wireguard_manager.py` добавлена поддержка `server_specs.graniwg_client_mtu` / `wireguard_client_mtu` / `client_mtu`, default остается `1420`;
  - для server id `7` в `server_specs` выставлено `graniwg_client_mtu=1280`, `graniwg_server_mtu=1280`, `mtu_test=lte_hetzner_2026_06_09`;
  - на самой FI-нode выполнено: backup `/etc/amnezia/amneziawg/wg0.conf.bak-20260609-mtu-test`, `MTU = 1280`, `ip link set dev wg0 mtu 1280`;
  - backend `simple_vpn.py` теперь добавляет hash фактического config в `config_revision`, чтобы mobile не мог случайно считать старый prepared-peer config тем же самым после изменения MTU;
  - `granivpn_api` перезапущен и healthy; smoke подтвердил generated config: `MTU = 1280`, `Endpoint = 204.168.160.160:51820`, config hash `299006760698`.
- Текущее состояние выдачи серверов после MTU-test:
  - `SE-STO-01` активен как рабочая референс-нода;
  - `FI-HEL-01` активен как тестовая LTE/MTU-нода;
  - `DE-FSN-01` оставлен inactive, чтобы не путать результаты.
- Следующий тест без сборки APK: полностью отключить VPN, выбрать `Helsinki / FI-HEL-01`, подключиться именно по LTE, проверить Speedtest/пакеты. Если после `MTU 1280` поток оживет, root cause подтвержден как MTU/fragmentation. Если нет — следующий серверный шаг: тест UDP-порта 443/4500 или переход GRANI на userspace/container runtime, так как личная Amnezia на Wi-Fi доказывает, что VPS в целом работоспособен.

## Заметка 2026-06-09: обновление целевой географии и Leaseweb Tokyo

- Важное уточнение пользователя: Leaseweb Tokyo/Asia уже куплен. Его больше нельзя считать "дальним и ненужным для европейского теста" вариантом.
- Обновленная бизнес-география GRANI:
  - основные вероятные клиенты: India, Indonesia, Pakistan, USA;
  - Европа остается полезной как технический baseline и часть покрытия, но не должна быть единственным критерием выбора провайдера/локации.
- Следствие для серверной стратегии:
  - Tokyo/Asia нужно рассматривать как реальный тестовый узел для азиатских маршрутов, особенно India/Indonesia/Pakistan;
  - для USA нужен отдельный американский узел, потому что европейские и токийские маршруты не дадут честную картину по latency/dataplane для США;
  - рекомендации "брать только EU-ноду" устарели для дальнейшего планирования.
- Практический подход:
  1. интегрировать уже купленный Leaseweb Tokyo как отдельную тестовую GRANIwg-ноду, не смешивая результаты с Hetzner DE/FI;
  2. проверить чистую связность и dataplane на Wi-Fi/LTE: handshake, RX/TX, Speedtest, YouTube/обычный web;
  3. сравнить Tokyo с рабочим Stockholm и проблемными Hetzner DE/FI;
  4. после Tokyo выбрать и купить отдельную USA-ноду у провайдера с хорошей UDP/WireGuard-репутацией;
  5. для India/Indonesia/Pakistan отдельно оценивать не только географическую близость, но и качество UDP path у мобильных операторов.
- Важное правило диагностики: если Tokyo работает нормально, а Hetzner DE/FI продолжают давать handshake без полезного RX, это еще сильнее укажет на provider/runtime/path проблему Hetzner, а не на общий баг мобильного клиента.

## Заметка 2026-06-10: подключение дополнительного агента

- Дополнительный агент подключился к проекту через SSH и прочитал полный актуальный контекст: /opt/grani/docs/VPN_WORK_CONTEXT.md.
- Приняты текущие правила работы: не создавать новые context/history файлы, фиксировать выводы только в этом документе, APK не собирать без прямой команды пользователя, destructive-команды не выполнять.
- Актуальный фокус по контексту: основной рабочий путь приложения — GRANIwg/AmneziaWG через clean/simple path; Xray/VLESS архивирован/R&D; текущие server-side исследования идут вокруг GRANIwg нод, LTE/MTU/UDP path и Leaseweb Tokyo/Asia как следующей тестовой ноды.
- В этом подключении код, backend, контейнеры и APK/AAB не изменялись.

## Заметка 2026-06-10: текущий multi-provider GRANIwg outage summary

- Пользователь описал текущий кризис инфраструктуры: старые рабочие TheHosting-ноды Bulgaria/London/Ireland отключены провайдером; Stockholm/Veesp работает на Android, но не идеально быстро; Hetzner Germany/Finland и Vultr Singapore дают симптом отсутствия входящих/полезных пакетов; проект фактически держится только на Stockholm.
- Read-only проверка backend/container state: granivpn_api healthy, nginx/postgres/redis/celery живы.
- DB-состояние серверов: active GRANIwg сейчас SE-STO-01 id=5, FI-HEL-01 id=7, SG-SIN-01 id=8; DE-FSN-01 id=6 online, но inactive; старые HU/UK/IE в maintenance.
- Read-only SSH-аудит нод через RemoteVPNManager:
  - SE-STO-01: wg0 active on UDP 51820, MTU 1420, peer lpfQ... has recent historical traffic 202 MiB RX / 2.55 GiB TX; это рабочий baseline.
  - FI-HEL-01: UDP 51820, MTU 1280 test active, peer lpfQ... endpoint есть, но latest handshake ~19h old и всего 920 B RX / 14 KiB TX; симптом stale/почти нет трафика.
  - SG-SIN-01: UDP 51820, full AWG params, wg0 counters 0/0, peer lpfQ... без endpoint/latest handshake; сервер пока вообще не видел успешный AWG handshake от телефона.
  - DE-FSN-01: inactive, UDP 39060, full AWG params, wg0 counters 0/0; не смешивать с active тестами.
- Важная разница симптомов: SG сейчас не доказывает плохой dataplane после handshake — там handshake вообще не дошел до wg0. FI отличается: handshake когда-то был, но трафик почти отсутствует/stale.
- Обнаружен риск чистоты теста: для одного device_uuid OnePlus MT2111 у user_id=1 есть несколько DB device rows/prepared peers с разными public keys (device id 225 и 237, оба сейчас is_active=false). Это может путать интерпретацию prepared-peer/cache логов; live тест нужно привязывать к конкретному public key/session.
- Рекомендуемый следующий шаг без APK и без config changes: live tcpdump/awg-show на SG или FI во время одной попытки connect. Матрица: если UDP-пакеты не приходят на внешний интерфейс — проблема client/cache/server selection или UDP path до провайдера; если приходят на eth0/enp1s0, но awg peer endpoint не появляется — obfuscation/profile/runtime mismatch; если handshake/RX появляется, но нет полезного TX/NAT — смотреть MTU/NAT/FORWARD/return path.

## Заметка 2026-06-10: SG-SIN live connect root cause и server-side fix

- Пользователь сообщил, что user_id=1 подключился к Singapore. Live-аудит SG-SIN-01 показал wg0 RX/TX = 0/0, у peer lpfQ0Etc... не было endpoint/latest handshake.
- Найден конкретный mismatch: backend DB для SG-SIN-01 (server_id=8) хранил full AmneziaWG params Jc=5,Jmin=10,Jmax=50,S1-S4,H1-H4, а runtime /etc/amnezia/amneziawg/wg0.conf на самой SG-нode был minimal Jc=4,Jmin=5,Jmax=60 без S1-S4/H1-H4. Это объясняет ноль handshake при клиентском профиле из backend.
- Применен server-side fix только на SG-SIN-01: сделан backup /etc/amnezia/amneziawg/wg0.conf.bak-20260610-awg-profile-sync, node config синхронизирован с DB full params, выполнен systemctl restart awg-quick@wg0.
- Проверка после фикса: wg show wg0 на SG теперь показывает jc=5,jmin=10,jmax=50,s1=138,s2=20,s3=35,s4=13,h1=1065396326,h2=1938780048,h3=2118021394,h4=2132846382; UDP 51820 слушает; peer lpfQ0Etc... сохранен с AllowedIPs=10.0.0.2/32.
- Минутное наблюдение после фикса все еще показало RX/TX=0/0 и отсутствие endpoint, потому что новых /simple-vpn/session/start на SG после фикса еще не было; последние попытки были до фикса (~09:54 UTC) и завершались stale_or_missing_handshake.
- Следующий обязательный тест: пользователь должен полностью отключить VPN и заново подключить Singapore. Если mobile cache уже содержит full config, после server-side sync должен появиться handshake. Если handshake не появится, следующая гипотеза — stale mobile local config/cache или UDP path до SG; тогда нужен forced config refresh/clear app cache либо live tcpdump на SG во время reconnect.

## Заметка 2026-06-10: SG reconnect after fix still RX=0, no fresh backend start

- После сообщения пользователя подключился, полученных пакетов 0 выполнены live-проверки SG-SIN-01.
- Важная корректировка: редактированный backend-generated config для SG/device 225 фактически содержит minimal params Jc=4,Jmin=5,Jmax=60, endpoint 149.28.139.231:51820, MTU 1420. Поэтому предыдущий server-side перевод SG на full params был неверным для текущего backend generator.
- SG node runtime возвращен к minimal params, matching фактически выдаваемому клиентскому config: backup /etc/amnezia/amneziawg/wg0.conf.bak-20260610-revert-minimal, systemctl restart awg-quick@wg0.
- DB metadata SG также синхронизирована на minimal { Jc:4,Jmin:5,Jmax:60}; повторная проверка redacted client config подтвердила minimal params + endpoint 149.28.139.231:51820.
- После этого SG runtime, DB и generated client config согласованы.
- Однако два read-only tcpdump окна на SG (	cpdump -ni enp1s0 udp port 51820) показали 0 packets captured; wg show wg0 все еще без endpoint/latest handshake, wg0 RX/TX=0/0.
- API logs за последнее окно не показали нового /api/simple-vpn/config, /simple-vpn/session/start или /session/verify по server_id=8; последний реальный start был около 10:02 UTC.
- Текущий вывод: после синхронизации SG profile телефон, вероятно, не сделал свежий backend/native start, а отображал локальное/cached VPN state. Следующий чистый шаг: полностью остановить локальный Android VPN/GRANI, убедиться что ключ исчез, затем нажать connect на SG один раз под одновременный tcpdump. Если backend увидит start, но tcpdump снова 0 — искать endpoint/cache/native send на Android; если tcpdump увидит UDP, но handshake нет — снова смотреть AWG profile/runtime.

## Заметка 2026-06-10: проверка Ubuntu 24.04 / AmneziaWG на SG и найденный UFW

- Проверен вопрос о возможном конфликте AmneziaWG/obfuscated WireGuard с Ubuntu 24.x на `SG-SIN-01` (`149.28.139.231`).
- На SG установлены official PPA noble-пакеты: `amneziawg`, `amneziawg-dkms`, `amneziawg-tools`; `dkms status` показывает `amneziawg/1.0.0, 6.8.0-124-generic, x86_64: installed`.
- Kernel module `amneziawg` загружен, `awg-quick@wg0` стартует успешно, `wg0` поднимается, NAT rule добавляется. В `dmesg` есть только стандартное предупреждение DKMS `module verification failed ... tainting kernel`, без runtime errors. На текущем этапе Ubuntu 24.04 не выглядит root cause.
- Найдена конкретная серверная проблема SG: `ufw` был включен с политикой `deny incoming`, открыт был только `22/tcp`; `51820/udp` для GRANIwg не был открыт.
- Применена server-side правка: `ufw allow 51820/udp`; теперь `ufw status verbose` показывает `51820/udp ALLOW IN` для IPv4 и IPv6.
- Важно: тестовый UDP-пакет grani-do -> SG через `nc -u` пока не появился в `tcpdump`, при том что ICMP и TCP/22 grani-do -> SG работают. Это может быть ограничение тестового источника/outbound UDP path; ключевая проверка теперь должна быть с телефона.
- Следующий обязательный live-тест: пользователь полностью отключает VPN, выбирает `SG-SIN-01`, подключается заново. На SG параллельно снять `tcpdump -ni enp1s0 udp port 51820` и `awg show wg0`. Ожидаемые исходы: если UDP/handshake/RX появятся — закрытый UFW был основной причиной; если tcpdump снова 0 — телефон/клиент не отправляет на SG endpoint или UDP path до Vultr SG режется до инстанса; если tcpdump видит UDP, но `awg` без handshake — снова смотреть AWG profile/runtime.

## Заметка 2026-06-10: SG clean app-data test, tiny RX then MTU 1280

- Пользователь очистил данные приложения, заново подключился к SG-SIN-01 и сообщил: несколько полученных пакетов появились, но Speedtest не прошёл.
- Live SG monitor после этого подтвердил частичное оживление: peer lpfQ0Etc... получил endpoint 94.180.243.40:40212, latest handshake был ~2.5 min old, transfer около 1.27 KiB received / 10.02 KiB sent; wg0 counters RX 1300 bytes / 13 packets, TX 10262 bytes / 156 packets, RX errors=2. Дальше counters не росли минуту.
- Это сменило симптом SG с 
o handshake / 0 packets на handshake + tiny packets, useful flow dead, аналогично MTU/fragmentation/path-shaping классу проблем.
- Применен backend/server-only MTU test на SG: server_specs.graniwg_client_mtu=1280, graniwg_server_mtu=1280, mtu_test=sg_vultr_2026_06_10; node /etc/amnezia/amneziawg/wg0.conf backup /etc/amnezia/amneziawg/wg0.conf.bak-20260610-mtu1280, MTU = 1280, systemctl restart awg-quick@wg0, ip link set wg0 mtu 1280. Prepared peer revisions for SG tagged sg-mtu1280-v1-20260610.
- Redacted generated config after MTU test confirmed client config for SG/device 225: Address=10.0.0.2/32, Endpoint=149.28.139.231:51820, MTU=1280, Jc=4,Jmin=5,Jmax=60.
- После MTU change был fresh backend /simple-vpn/config и /session/start на SG в 10:27:22 UTC for new device_uuid ac13f06-2c56-4263-83d3-d72646093e54, device DB id 225. Но SG monitor immediately after showed no endpoint/handshake and wg0 counters 0/0 after restart.
- Важное ограничение: /session/start вызывается до native start, поэтому он не доказывает, что Android runner реально поднял tunnel. client_logs по device id 225 после 10:18 UTC отсутствуют, то есть native_start_ok / error details на backend не дошли.
- Текущий следующий шаг: нужен logcat с телефона за попытку SG после MTU 1280 или live tcpdump строго во время нового connect. Без logcat невозможно отличить native runner failure / Android permission / local cache/start issue от UDP path issue после config fetch.


## Заметка 2026-06-10: SG logcat after app-data clear shows cached reconnect path

- Пользователь приложил logcat `логи.txt` после удаления данных приложения/повторной авторизации и подключения к SG; результат прежний: несколько RX было, Speedtest не прошел.
- Logcat: после авторизации Google OK (`13:41:52 MSK`) приложение в `13:42:03` вызвало `disconnectAmneziaWg` и затем `connectAmneziaWg`; native runner стартовал: `startAmneziaWgConnection source=simple_vpn session=223e600e-...`, `parsed AmneziaWG config, peers=1`, `Tunnel UP`, `peer(0CCY...2RAw) - Sending handshake initiation`.
- В logcat нет handshake response; далее каждые ~5s идут `Sending handshake initiation`, затем `Handshake did not complete after 5 seconds, retrying`.
- Backend logs по этой же сессии: `/api/simple-vpn/session/start` был в `10:42:04 UTC` для `device_id=bac13f06-...`, `server_id=8`, `session_id=223e600e-...`; но рядом не было нового `/api/simple-vpn/config`. Последний `/config` по SG был раньше (`10:27:22 UTC`).
- Следовательно, это был не полностью fresh provisioning/config fetch, а быстрый reconnect из local config cache. Это совпадает с наблюдением пользователя, что запуск мог быть не чистым.
- SG server state around check: endpoint/handshake существовал от более ранней попытки, counters tiny (`~1.96 KiB RX / 12.95 KiB TX`), но текущий tcpdump после лога снова видел 0 live UDP packets; полезный flow не стартовал.
- Текущий вывод: Android native runner реально стартует и пытается handshake к SG peer `0CCY...`, но для этой cached попытки сервер не получает live UDP/handshake response path. Для чистого следующего теста нужно гарантировать forced config fetch (не local cache) и держать tcpdump ровно во время нажатия connect. Если `/config` не появляется, это не чистый тест server provisioning/MTU.


## 2026-06-10 11:05 UTC - SG/Vultr railcuber log analysis and UDP 443 server-side test

- User report/logcat: account `railcuber@gmail.com`, first attempt did not show Android VPN permission, second attempt connected but RX stayed minimal and Speedtest failed.
- Logcat analysis:
  - auth succeeded as `user_id=23`;
  - first "no permission dialog" attempt happened while app was routed through `/trial-ended` / access-expired flow and called `disconnectVpn: source=trial_ended_paywall reason=access_expired`, so it was not a real native tunnel start;
  - second attempt requested VPN permission, user allowed it, native `connectAmneziaWg` started;
  - backend issued SG config and `session/start` used `server_id=8`, session `bd49ccfc-8ab7-43ef-912e-7b25bb83b2ea`;
  - native runner reached `Tunnel UP` and received one handshake response from peer `0CCY...2RAw`;
  - after about 15 seconds native logs switched to `Retrying handshake because we stopped hearing back` / `Handshake did not complete after 5 seconds`.
- Server confirmation before port test:
  - SG peer for `railcuber` public key `zZXmFLb62n7qT3zLhl276v4AQMAzq25wMHwwAU1Un3w=` appeared on node;
  - endpoint `94.180.243.40:43179`, allowed IP `10.0.0.3/32`;
  - transfer stayed tiny (`852 B received`, `8.37 KiB sent`) and counters did not grow during monitor;
  - `wg0` showed RX errors (`errors=10`);
  - conclusion: not an Android permission issue and not wrong server selection; SG has handshake + tiny traffic, then useful data-plane stalls. MTU 1280 did not fix it.
- Applied next server-only reversible test to SG/Vultr:
  - changed SG node `/etc/amnezia/amneziawg/wg0.conf` `ListenPort` from `51820` to `443`;
  - backup on SG: `/etc/amnezia/amneziawg/wg0.conf.bak-20260610110434-port443`;
  - restarted `awg-quick@wg0`;
  - updated DB `servers.wireguard_port` for server id=8 to `443`;
  - bumped `device_server_peers.config_revision` with suffix `:sg-port443-v1-20260610110434`;
  - backend redacted config check now shows `Endpoint = 149.28.139.231:443`, `MTU = 1280`, `Jc/Jmin/Jmax = 4/5/60`;
  - docker check: `granivpn_api` remains healthy.
- Next phone test:
  - fully disconnect VPN;
  - to avoid old local cached endpoint `:51820`, clear app data or otherwise force fresh `/simple-vpn/config`;
  - authorize, select Singapore, connect again;
  - expected backend logs should show config issued/session start for `server_id=8`; native config should use endpoint `149.28.139.231:443`.
- If UDP 443 still gives handshake + tiny RX / failed Speedtest, likely issue is Vultr/route/GRANIwg data-plane compatibility rather than client selection/cache. Next server-only candidates: test UDP 4500 on SG, then test same SG with clean classic WireGuard or known-working AmneziaWG container/profile style.


## 2026-06-10 11:13 UTC - SG UDP 443 retest log shows UFW miss, 443/udp opened

- User retested `railcuber@gmail.com`; result unchanged, attached fresh logcat.
- Logcat:
  - auth succeeded as `user_id=23`, route `/main`;
  - `connectAmneziaWg` requested Android VPN permission and user allowed it;
  - native `startAmneziaWgConnection` session `2659736a-a595-4f41-a16f-f9d1919aec83`;
  - native runner parsed config, created peer `0CCY...2RAw`, tunnel state `UP`;
  - no `Received handshake response`; only repeated `Sending handshake initiation`.
- Backend logs:
  - fresh `/simple-vpn/config` was issued for `user_id=23`, `server_id=8`;
  - `/session/start` used `server_id=8`, session `2659736a-a595-4f41-a16f-f9d1919aec83`;
  - confirms this test used fresh backend path after the port change.
- SG monitor right after test:
  - node listens on `443`, `wg0` up, MTU 1280, params `Jc=4,Jmin=5,Jmax=60`;
  - peer `zZXm...` exists with `AllowedIPs=10.0.0.3/32`;
  - `wg0` counters stayed `RX=0/TX=0`, no endpoint/latest handshake.
- Found cause in the UDP 443 test setup: SG UFW was active with default `deny incoming`; before fix it allowed only `22/tcp` and old `51820/udp`, not `443/udp`.
- Applied server-side firewall fix on SG:
  - `ufw allow 443/udp`;
  - `ufw status verbose` now shows `443/udp ALLOW IN` for IPv4 and IPv6;
  - `ss -lunp` confirms AWG listening on UDP `443`.
- Post-UFW monitor still showed `RX=0/TX=0`, likely because the existing Android tunnel had already stopped useful handshake attempts. Next test must be a fresh reconnect after this UFW fix.
- Next phone test: fully disconnect VPN, connect Singapore again. App data clear is optional if config already fresh, but safest is clear app data/force config fetch. Expected endpoint remains `149.28.139.231:443`.


## 2026-06-10 11:19 UTC - SG reconnect after opening UDP 443: handshake and small traffic restored

- User reconnected to Singapore after SG UFW `443/udp` was opened and reported that packets are now visible.
- Live SG monitor confirmed improvement:
  - peer `zZXmFLb62n7qT3zLhl276v4AQMAzq25wMHwwAU1Un3w=` endpoint `94.180.243.40:41251`;
  - latest handshake existed after reconnect;
  - transfer appeared: about `3.24 KiB received`, `49-63 KiB sent`;
  - `wg0` counters: `RX 3320 bytes / 25 packets`, `TX ~64 KiB / 266 packets`, RX errors stayed at `4`.
- However traffic did not become a healthy flow:
  - RX stopped growing at `3320 bytes / 25 packets`;
  - latest handshake aged to `3m+`;
  - TX continued to grow slowly, likely keepalive/retry/control traffic.
- Backend logs for current attempt:
  - fresh SG config issued at `11:14:33 UTC`;
  - session starts at `11:14:34` and `11:15:04 UTC` for `user_id=23`, `server_id=8`;
  - no new `session stop` after current start in checked window.
- Firewall/routing audit on SG:
  - `ufw` active, incoming allows `443/udp`;
  - `net.ipv4.ip_forward=1`;
  - `FORWARD` chain has wg0 ACCEPT rules from wg0 PostUp;
  - NAT MASQUERADE rule exists for `10.0.0.0/24 -> enp1s0`;
  - counters on FORWARD/NAT matched the first forwarded packets, so forwarding is not completely blocked.
- Current conclusion: opening `443/udp` fixed the zero-packet part of the port test, but SG still has the same class of problem as before: handshake + tiny initial traffic, then useful flow stalls. If Speedtest still fails, next SG server-only candidate is moving from UDP `443` to UDP `4500` with matching UFW allow and config revision bump, or testing clean classic WireGuard/AWG profile on the same Vultr node.


## 2026-06-10 11:24 UTC - SE Stockholm working-node parameters compared with SG

- Read-only comparison of working-ish Sweden node `SE-STO-01` (server id=5) vs Singapore `SG-SIN-01` (server id=8).
- Sweden DB/runtime:
  - provider/location: Veesp Stockholm, public IP `13.140.9.211`;
  - OS/kernel: Ubuntu 26.04 LTS, kernel `7.0.0-14-generic`;
  - GRANIwg config path `/etc/amnezia/amneziawg/wg0.conf`;
  - endpoint port `51820/udp`;
  - interface `wg0`, MTU `1420`;
  - AWG params: `Jc=4`, `Jmin=5`, `Jmax=60`, `H1=1`, `H2=2`, `H3=3`, `H4=4`;
  - default route via `eth0`;
  - UFW inactive;
  - IPv4 forwarding enabled;
  - NAT rule: `10.0.0.0/24 -> eth0 MASQUERADE`;
  - PostUp only allows return traffic to wg0 with conntrack: `-o wg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT`.
- Singapore current runtime:
  - provider/location: Vultr Singapore, public IP `149.28.139.231`;
  - OS/kernel: Ubuntu 24.04.4 LTS, kernel `6.8.0-124-generic`;
  - endpoint port currently `443/udp` after test;
  - interface `wg0`, MTU `1280`;
  - same minimal AWG params as Sweden: `Jc=4`, `Jmin=5`, `Jmax=60`, `H1-H4=1..4`;
  - default route via `enp1s0`;
  - UFW active, allows `22/tcp`, `51820/udp`, `443/udp`;
  - IPv4 forwarding enabled;
  - NAT rule: `10.0.0.0/24 -> enp1s0 MASQUERADE`;
  - PostUp broadly allows `-i wg0` and `-o wg0`.
- Key conclusion: Sweden is not using special/fuller AWG obfuscation; it uses the same minimal AWG profile as SG. The meaningful differences are provider/path, UDP port, MTU, UFW state, kernel/OS, and interface/routing environment. Since SG now gets handshake + tiny traffic on UDP 443 but still stalls, the issue is less likely to be AWG parameter mismatch and more likely UDP path/provider/port or node environment.


## 2026-06-10 11:39 UTC - Isolated clean AmneziaWG test profile created on SG

- Created an isolated test AmneziaWG profile on `SG-SIN-01` without touching production `wg0`.
- Purpose: verify whether Vultr SG can carry a clean obfuscated WireGuard/AmneziaWG tunnel independently of GRANI backend prepared peers/cache/session logic.
- Test interface:
  - interface: `awgtest`;
  - server config: `/etc/amnezia/amneziawg/awgtest.conf`;
  - client config on SG: `/etc/amnezia/amneziawg-test/sg-awgtest-client.conf`;
  - exported copy on `grani-do`: `/tmp/sg-awgtest-client.conf`;
  - local exported copy in Codex outputs: `outputs/sg-awgtest-client.conf`;
  - endpoint: `149.28.139.231:4500`;
  - subnet: `10.77.0.0/24`, server `10.77.0.1`, client `10.77.0.2/32`;
  - MTU: `1280`;
  - AWG params: `Jc=4`, `Jmin=5`, `Jmax=60`, `H1-H4=1..4`;
  - UFW: `4500/udp` allowed for IPv4 and IPv6;
  - service: `awg-quick@awgtest` active.
- Production SG remains on `wg0`, endpoint currently `149.28.139.231:443`, not modified by this test.
- Test procedure:
  - import `sg-awgtest-client.conf` into an AmneziaWG/AmneziaVPN-compatible client (not the production GRANI app unless it supports manual config import);
  - connect this manual profile;
  - monitor on SG with `awg show awgtest` and `ip -s link show awgtest`;
  - if `awgtest` also stalls after handshake + tiny RX, SG/Vultr/UDP path or AmneziaWG environment is likely the issue;
  - if `awgtest` works well, production GRANIwg config/lifecycle should be investigated further.


## 2026-06-10 11:48 UTC - Isolated SG awgtest succeeded on Wi-Fi, LTE still poor

- User imported the isolated `sg-awgtest-client.conf` into AmneziaVPN/AmneziaWG-compatible client.
- During import the client asked whether to enable obfuscation; user enabled it. This is important: the test was indeed obfuscated AmneziaWG, not plain WireGuard.
- Wi-Fi/manual awgtest result:
  - connection established;
  - packets flowed both directions;
  - Speedtest was good;
  - screenshot showed approximately `681137 bytes / 129 packets received` and `29520 bytes / 158 packets sent` at 14 seconds on the phone.
- Server-side confirmation on SG `awgtest`:
  - endpoint `94.180.243.40:43142`;
  - latest handshake present;
  - transfer reached `84.69 MiB received`, `117.30 MiB sent`;
  - link counters: RX `88,803,972 bytes / 114,571 packets`, TX `122,994,152 bytes / 124,991 packets`;
  - confirms full useful flow, not just handshake.
- User also tested awgtest on LTE:
  - connection exists but packets do not flow / Speedtest fails;
  - for now user says LTE can be deprioritized.
- Key conclusion:
  - Vultr SG can carry obfuscated AmneziaWG successfully on at least Wi-Fi path;
  - SG/provider/kernel are not globally incompatible with AmneziaWG;
  - production GRANI `wg0` problem is more likely in production port/profile/client import/runtime differences, peer lifecycle, or app-generated config behavior.
- Important difference to investigate next:
  - manual AmneziaVPN import explicitly enabled obfuscation;
  - GRANI app must ensure generated config/native runner uses AmneziaWG mode/obfuscation exactly, not interpreted as plain WG or missing optional obfuscation flags.


## 2026-06-10 11:54 UTC - SG production moved to UDP 4500 and configs compared

- User asked to move SG production port to 4500 and compare configs: Sweden, successful SG awgtest, and current GRANI-generated SG config.
- Applied production SG change:
  - stopped isolated test service `awg-quick@awgtest` to free UDP `4500`;
  - backed up production config: `/etc/amnezia/amneziawg/wg0.conf.bak-20260610115331-prod4500`;
  - changed production SG `/etc/amnezia/amneziawg/wg0.conf` `ListenPort` from `443` to `4500`;
  - restarted `awg-quick@wg0`;
  - UFW already allowed `4500/udp`;
  - updated DB `servers.wireguard_port` for server id=8 to `4500`;
  - bumped active SG `device_server_peers.config_revision` suffix `:sg-prod4500-v1-20260610115331`.
- Verification:
  - `awg show wg0` on SG now shows `listening port: 4500`;
  - `ss -lunp` shows UDP `4500` listener;
  - backend generated SG config for latest `railcuber` device now shows `Endpoint = 149.28.139.231:4500`, `MTU = 1280`, `Jc=4`, `Jmin=5`, `Jmax=60`.
- Config comparison summary:
  - Sweden production:
    - endpoint `13.140.9.211:51820`;
    - server MTU `1420`;
    - AWG params `Jc=4,Jmin=5,Jmax=60,H1-H4=1..4`;
    - UFW inactive;
    - PostUp uses conntrack on return path;
    - DNS in generated clients not checked in this run.
  - SG successful manual `awgtest`:
    - endpoint `149.28.139.231:4500`;
    - MTU `1280`;
    - same AWG params `Jc=4,Jmin=5,Jmax=60,H1-H4=1..4`;
    - client DNS `1.1.1.1, 8.8.8.8`;
    - isolated subnet `10.77.0.0/24`;
    - PostUp uses conntrack on return path.
  - SG production GRANI generated config after change:
    - endpoint `149.28.139.231:4500`;
    - MTU `1280`;
    - same AWG params `Jc=4,Jmin=5,Jmax=60`;
    - client DNS `1.1.1.1, 9.9.9.9`;
    - production subnet `10.0.0.0/24`;
    - same `AllowedIPs=0.0.0.0/0`, `PersistentKeepalive=25`.
- Current strongest remaining differences between successful awgtest and GRANI production:
  - manual AmneziaVPN import explicitly asked to enable obfuscation; need ensure GRANI native runner interprets/generated config as AmneziaWG obfuscated mode identically;
  - production `wg0` has backend peer lifecycle/suspend/restore and multiple peers, while awgtest is one static peer;
  - production server PostUp allows all `-o wg0`; awgtest/Sweden use conntrack return rule. This is unlikely to block but remains a config difference;
  - DNS differs (`8.8.8.8` vs `9.9.9.9`), unlikely to explain handshake/data-plane stall but noted.
- Next phone test: force fresh SG config in GRANI app and connect Singapore. Expected generated endpoint is now `149.28.139.231:4500`.


## 2026-06-10 11:59 UTC - Budapest/London/Sweden config search and SG comparison

- User asked to explain config differences and check whether Budapest/London/Sweden configs are available on server.
- DB still contains old nodes:
  - `id=1 HU-BUD-01`, Budapest, `45.12.132.94`, inactive, old path `/etc/wireguard/wg0.conf`, port `51820`;
  - `id=3 UK-LON-01`, London, `45.140.167.123`, inactive, old path `/etc/wireguard/wg0.conf`, port `51820`;
  - `id=4 IE-DUB-01`, Dublin, `194.4.51.125`, inactive, old path `/etc/wireguard/wg0.conf`, port `51820`;
  - `id=5 SE-STO-01`, Stockholm, active, AmneziaWG path `/etc/amnezia/amneziawg/wg0.conf`, port `51820`;
  - `id=8 SG-SIN-01`, Singapore, active, AmneziaWG path `/etc/amnezia/amneziawg/wg0.conf`, port now `4500`.
- SSH/live config result:
  - Budapest and London SSH timed out, expected because old TheHosting servers were reportedly shut down; live configs cannot currently be read from those hosts.
  - Sweden live config is accessible and was read redacted.
  - Singapore live config and backups are accessible.
- Sweden current live config:
  - `ListenPort=51820`, `MTU=1420`;
  - `Jc=4,Jmin=5,Jmax=60,H1-H4=1..4`;
  - `PostUp`: `-i wg0 ACCEPT`, return `-o wg0` only with conntrack RELATED,ESTABLISHED, NAT `10.0.0.0/24 -> eth0`;
  - UFW inactive.
- Singapore current production config after prod4500:
  - `ListenPort=4500`, `MTU=1280`;
  - `Jc=4,Jmin=5,Jmax=60,H1-H4=1..4`;
  - `PostUp`: `-i wg0 ACCEPT`, broad `-o wg0 ACCEPT`, NAT `10.0.0.0/24 -> enp1s0`;
  - UFW active with `51820/udp`, `443/udp`, `4500/udp` allowed.
- Key comparison:
  - Sweden and SG use the same minimal AmneziaWG obfuscation params; not a full-param vs minimal-param difference.
  - Main differences are port, MTU, UFW state, interface name, PostUp return rule style, provider/kernel/path, and production lifecycle.
  - Old Budapest/London DB paths point to `/etc/wireguard/wg0.conf`, so they may have been classic WireGuard-era configs or old naming; because servers are down, cannot verify live AWG/WG runtime now.


## 2026-06-10 12:14 UTC - SG old `/etc/wireguard` layout AmneziaWG test created

- Corrected assumption: `/etc/wireguard/wg0.conf` does not prove classic WireGuard. Old HU/UK/IE could have been GRANIwg/AmneziaWG while still using the classic WireGuard config directory.
- SG runtime check:
  - `/usr/local/bin/wg -> /usr/bin/awg`;
  - `/usr/local/bin/wg-quick -> /usr/bin/awg-quick`;
  - therefore commands named `wg`/`wg-quick` on SG are AmneziaWG wrappers, not plain WireGuard.
  - `/usr/bin/awg-quick` searches `/etc/amnezia/amneziawg/<iface>.conf` when called by interface name, but can run an explicit config path.
- Created isolated old-layout test on SG without touching production `wg0`:
  - server config path: `/etc/wireguard/wgold.conf`;
  - started with explicit `wg-quick up /etc/wireguard/wgold.conf`;
  - runtime confirms `ip link add wgold type amneziawg`;
  - interface: `wgold`;
  - endpoint: `149.28.139.231:51820`;
  - subnet: `10.88.0.0/24`, server `10.88.0.1`, client `10.88.0.2/32`;
  - MTU `1420`, matching old/Sweden style;
  - AWG params `Jc=4,Jmin=5,Jmax=60,H1-H4=1..4`;
  - PostUp old/Sweden-like: `-i wgold ACCEPT`, return `-o wgold` only RELATED,ESTABLISHED, NAT via `enp1s0`;
  - UFW already allows `51820/udp`;
  - production `wg0` remains on `4500/udp`.
- Exported client config:
  - on SG: `/etc/amnezia/amneziawg-test/sg-oldlayout-wgold-client.conf`;
  - on grani-do: `/tmp/sg-oldlayout-wgold-client.conf`;
  - local output: `outputs/sg-oldlayout-wgold-client.conf`.
- Test meaning:
  - If manual AmneziaVPN import of old-layout `wgold` works like `awgtest`, then old path/layout itself is viable and production GRANI issue is app/native/config lifecycle.
  - If `wgold` behaves like production GRANI and fails while `awgtest` works, then port/MTU/layout differences matter more than expected.


## 2026-06-10 12:55 UTC - AmneziaWG v2 docs comparison with GRANI configs

- User clarified that working AmneziaVPN uses `AmneziaWG (version 2)` and asked to compare documentation with GRANI protocol.
- Official AmneziaWG repos/docs checked:
  - `amneziawg-go` README describes AmneziaWG as WireGuard-Go fork with DPI obfuscation and documents:
    - `Jc/Jmin/Jmax`: junk packets before each handshake;
    - `S1-S4`: padding sizes for handshake initial/response/cookie/transport messages;
    - `H1-H4`: custom message headers;
    - `I1-I5`: custom signature packets sent before each handshake;
  - `amneziawg-linux-kernel-module` README says all params must match between client and server except `Jc/Jmin/Jmax`, which may vary. It documents `S1/S2` and `H1-H4` as significant shared parameters.
- GRANI current generated SG config contains only:
  - `Jc=4`, `Jmin=5`, `Jmax=60`;
  - no `S1-S4`, no `H1-H4`, no `I1-I5`.
- GRANI backend code already supports formatting full AWG params in `WireGuardManager._format_awg_params`: `Jc/Jmin/Jmax`, `S1-S4`, `H1-H4`, `I1-I5`.
- GRANI Android vendored `amneziawg-android` also supports v2 fields:
  - `Interface.java` parses and serializes `S1-S4`, `H1-H4`, `I1-I5` in addition to `Jc/Jmin/Jmax`;
  - latest vendored commit shown locally: `c4b568a chore: bump awg-go to the latest version (#51)`.
- SG server tools:
  - `wg` and `wg-quick` are symlinks to `awg` and `awg-quick`;
  - tools version on SG: `amneziawg-tools v1.0.20210914`;
  - runtime can accept AWG params.
- Current strongest hypothesis:
  - GRANI is running a minimal/legacy AmneziaWG profile, not a full AmneziaWG v2-style obfuscation profile;
  - AmneziaVPN UI checkbox “enable obfuscation” likely enables/keeps a richer v2 profile or client behavior;
  - this explains why AmneziaVPN works while GRANI app with only `Jc/Jmin/Jmax` stalls after handshake/tiny traffic.
- Next practical backend-only experiment:
  - choose full v2 AWG params (`Jc/Jmin/Jmax`, `S1-S4`, `H1-H4`, optionally `I1-I5`);
  - apply the same full params to SG server config and DB `graniwg_obfuscation_key`;
  - generated GRANI client config should then include all matching fields;
  - no APK required if current Android parser supports these fields, but fresh config fetch is required.

## 2026-06-10 13:12 UTC - rail.tamaew@gmail.com SG GRANI app failure diagnosis

- User report/screenshot: `rail.tamaew@gmail.com`, GRANI app shows Protected/Connected, Android VPN dialog shows chain `grani-awg`, duration ~26s, sent `22102 bytes / 132 packets`, received only `307 bytes / 5 packets`; user says VPN does not work.
- API logs around 13:01-13:03 UTC show the phone did request Singapore:
  - `/api/simple-vpn/config` issued `user_id=1`, `server_id=8`, `protocol=graniwg` at `13:01:53 UTC`;
  - `session/start` for device UUID `bac13f06-2c56-4263-83d3-d72646093e54`, session `f0c73159-40e4-4839-a79b-27cebf242fdb`, `server_id=8` at `13:02:06 UTC`;
  - `session/verify` reported `verified=True`, but counters remained tiny: first `rx=2164 tx=39574`, then `rx=3832 tx=60703`.
- DB/user check:
  - `rail.tamaew@gmail.com` is `user_id=1`;
  - devices found: DB device `237` UUID `e8a74313-e8ff-4b5d-bd06-8060e0f68af0`, key `zlyM4MV2...DJi9xSo=`, inactive; DB device `225` UUID `bac13f06-2c56-4263-83d3-d72646093e54`, key `lpfQ0Etc...sbIpnVM=`, inactive;
  - actual current SG session used old/current traffic key `lpfQ0Etc...sbIpnVM=` and SG peer `10.0.0.2`.
- Generated config for device `225` on SG now includes the full S/H profile and is not stale:
  - `Address=10.0.0.2/32`, DNS `1.1.1.1,9.9.9.9`, `MTU=1280`, endpoint `149.28.139.231:4500`, `AllowedIPs=0.0.0.0/0`, `PersistentKeepalive=25`;
  - includes `Jc=5,Jmin=10,Jmax=50`, `S1=138,S2=20,S3=35,S4=13`, `H1-H4` full ranges;
  - peer revision includes `sg-fullawg-v2-s-h-20260610125842`.
- SG runtime after screenshot:
  - `wg0` listening on `4500`, full S/H params active;
  - peer `lpfQ0Etc...sbIpnVM=` endpoint `94.180.243.40:41915`, latest handshake ~minutes old, transfer only `3.74 KiB received / 85.14 KiB sent`;
  - `ip -s link wg0`: RX `3832 bytes / 24 packets`, TX `87180 bytes / 336 packets`.
- SG production routing/NAT check:
  - `/etc/amnezia/amneziawg/wg0.conf` has `Address=10.0.0.1/24`, `ListenPort=4500`, `MTU=1280`, full S/H params, peer `10.0.0.2/32`;
  - `net.ipv4.ip_forward=1`, `net.ipv6.conf.all.forwarding=1`;
  - route for `10.0.0.0/24 dev wg0` exists;
  - NAT exists: `POSTROUTING -s 10.0.0.0/24 -o enp1s0 -j MASQUERADE`;
  - FORWARD accepts `-i wg0` and `-o wg0`;
  - nft/UFW counters for `10.0.0.0/24` show only ~11 forwarded/NATed packets, matching the tiny client traffic rather than a mass server-side drop.
- Client log table confirms the same pattern:
  - latest SG entries for `user_id=1`, `server_id=8` are `traffic_first_seen/vpn_data_verified`, but only kilobytes;
  - earlier SG entries before full S/H were stale/missing handshake or zero endpoint;
  - Sweden `server_id=5` entries for the same account/key earlier today show very large traffic counters through `graniwg` (hundreds of MB RX and GB TX), so the GRANI client path can carry traffic at least on Sweden.
- Interpretation as of this check:
  - Not an auth/subscription failure, not wrong server selection, not Cloudflare/API, not missing SG UFW/NAT, and not a stale pre-v2 SG config for this device;
  - SG GRANI app tunnel reaches handshake and a little data, then does not carry useful traffic;
  - because Sweden over `graniwg` has large counters for the same account/key, the next comparison should be SG production profile/provider/path vs known-good Sweden/manual Amnezia profile, not more random port changes.
- Suggested next targeted tests:
  - while user is actively connected to SG in GRANI, run a short server-side tcpdump/counter watch and ask them to open a simple IPv4 URL, to see whether payload enters `wg0` at all;
  - export/import the exact current production SG config into AmneziaVPN for the same peer (or a fresh test peer) to split “SG production profile bad” from “GRANI embedded runner bad”;
  - if exact SG production config works in AmneziaVPN but not GRANI, focus on Android embedded AmneziaWG runner/library/version/lifecycle and plan APK-side fix; if it fails in Amnezia too, fix SG profile/subnet/provider settings server-side.

## 2026-06-10 13:24 UTC - Exact SG production config exported for AmneziaVPN manual test

- Created a separate manual-test peer on Singapore production `wg0` to compare exact GRANI SG production profile in AmneziaVPN vs GRANI Android runner.
- No existing peer was changed or removed.
- New SG test peer:
  - VPN IP: `10.0.0.200/32`;
  - public key: `qqfj2Yn3elyFBBIKsF1eMh1Veha/Lv3PxnFZHuCmR28=`;
  - server-side persisted in `/etc/amnezia/amneziawg/wg0.conf` and active in `awg show wg0 allowed-ips`.
- Exported client config paths:
  - SG remote: `/etc/amnezia/amneziawg-test/sg-production-exact-amnezia-test-20260610132009.conf`;
  - grani-do copy: `/tmp/sg-production-exact-amnezia-test-20260610132009.conf`;
  - local Codex output: `outputs/sg-production-exact-amnezia-test-20260610132009.conf`.
- Exported config characteristics:
  - `Address=10.0.0.200/32`;
  - DNS `1.1.1.1, 9.9.9.9`;
  - `MTU=1280`;
  - exact SG production AWG params: `Jc=5,Jmin=10,Jmax=50,S1=138,S2=20,S3=35,S4=13,H1-H4=1065396326-1762624561 / 1938780048-1988422668 / 2118021394-2124378345 / 2132846382-2134177661`;
  - endpoint `149.28.139.231:4500`;
  - `AllowedIPs=0.0.0.0/0`, `PersistentKeepalive=25`.
- First creation script exited non-zero only because the final cosmetic `sed` peer display command had a bad expression; the peer and config were already created successfully. A follow-up fetch script confirmed the peer exists and copied the config.
- Test interpretation:
  - If this exact SG production config works in AmneziaVPN, then SG server profile is viable and the remaining breakage is likely in GRANI Android embedded AmneziaWG runner/library/lifecycle/config parsing.
  - If this exact SG production config also fails in AmneziaVPN, then the issue is server/profile/provider-side for SG production despite handshake/NAT being present.

## 2026-06-10 13:36 UTC - SG exact S/H test failed; production reverted to awgtest-style J-only

- User imported `outputs/sg-production-exact-amnezia-test-20260610132009.conf` into AmneziaVPN and reported it does not work; screenshots show AmneziaVPN connected but Android VPN stats remain tiny/zero RX:
  - examples: sent `26783 bytes / 202 packets`, received `227 bytes / 3 packets`; later sent `32028 bytes / 360 packets`, received `0 bytes / 0 packets`.
  - screenshot also showed AmneziaVPN split tunneling enabled, which should be disabled for clean tests, but server counters independently confirmed almost no tunneled payload.
- Server check for the manual test peer `10.0.0.200/32` (`qqfj2Yn3elyFBBIKsF1eMh1Veha/Lv3PxnFZHuCmR28=`):
  - endpoint `94.180.243.40:44882`;
  - latest handshake present;
  - transfer only `7.45 KiB received / 37.11 KiB sent`;
  - `wg0` interface RX only `7624 bytes / 33 packets`, TX `37998 bytes / 302 packets`;
  - NAT/forward counters for `10.0.0.0/24` only ~22 packets.
- Interpretation changed:
  - exact SG production full `S/H` profile fails even in AmneziaVPN;
  - therefore the issue is not only GRANI Android embedded runner;
  - the full `S/H` experiment was likely the wrong direction for SG production.
- Compared known-working manual `awgtest` config with production:
  - working `awgtest`: `Address=10.77.0.2/32`, endpoint `149.28.139.231:4500`, `MTU=1280`, only `Jc=4,Jmin=5,Jmax=60`, no `S1-S4`, no `H1-H4`;
  - failed full production exact test had `MTU=1280`, endpoint `4500`, but `Jc=5,Jmin=10,Jmax=50` plus `S1-S4` and `H1-H4` ranges.
- Action taken: reverted SG production `wg0` to awgtest-style J-only profile:
  - backup created: `/etc/amnezia/amneziawg/wg0.conf.bak-202606101330-awgtest-style-j-only`;
  - current `/etc/amnezia/amneziawg/wg0.conf`: `ListenPort=4500`, `MTU=1280`, `Jc=4,Jmin=5,Jmax=60`, no explicit `S/H/I` lines;
  - `awg show wg0` runtime confirms `jc=4,jmin=5,jmax=60`; runtime still displays default `h1=1,h2=2,h3=3,h4=4` from AWG defaults;
  - existing peers retained: user device `10.0.0.2`, extra peer `10.0.0.3`, manual test peer `10.0.0.200`.
- DB sync completed after fixing SQLAlchemy JSON bind issue:
  - `servers.graniwg_obfuscation_key` for SG set to `{"Jc":4,"Jmin":5,"Jmax":60}`;
  - active SG `device_server_peers.config_revision` bumped with `sg-awgtest-style-j-only-202606101330`;
  - backend-generated SG config for `rail.tamaew@gmail.com` device `225` now contains only `Jc=4,Jmin=5,Jmax=60`, endpoint `149.28.139.231:4500`, `MTU=1280`, no `S/H`.
- New manual AmneziaVPN test config generated for same test peer under current J-only production state:
  - local output: `outputs/sg-production-awgtest-style-j-only-202606101330.conf`;
  - grani-do copy: `/tmp/sg-production-awgtest-style-j-only-202606101330.conf`;
  - uses `Address=10.0.0.200/32`, `DNS=1.1.1.1,9.9.9.9`, `MTU=1280`, `Jc=4,Jmin=5,Jmax=60`, endpoint `149.28.139.231:4500`, `AllowedIPs=0.0.0.0/0`, `PersistentKeepalive=25`.
- Docker state after change: `granivpn_api` remains healthy; all core containers are up.
- Next test instructions:
  - In AmneziaVPN, disable split tunneling for a clean test;
  - import/use `outputs/sg-production-awgtest-style-j-only-202606101330.conf`;
  - if J-only exact production works in AmneziaVPN, then keep SG production J-only and retest GRANI app after fresh config fetch;
  - if J-only exact production still fails in AmneziaVPN, compare production `wg0` vs `awgtest` deeper: server key/profile defaults, interface/subnet behavior, UFW/nft interaction, or run a fresh isolated known-good interface on a different open port.

## 2026-06-10 13:45 UTC - J-only SG production config works in AmneziaVPN with obfuscation enabled

- User tested the new manual config `outputs/sg-production-awgtest-style-j-only-202606101330.conf` in AmneziaVPN.
- Result: it worked.
- Important user observation: during import/connect AmneziaVPN again asked whether obfuscation is needed; user enabled obfuscation, and then traffic worked.
- This confirms:
  - the previous full `S/H` production experiment was wrong for current SG setup;
  - the working SG shape is the simple/J-only AmneziaWG profile (`Jc=4,Jmin=5,Jmax=60`, no explicit `S1-S4`, no explicit `H1-H4`) with AmneziaWG obfuscation mode enabled on the client;
  - Singapore server/provider/port `4500` can work when the client treats the profile as AmneziaWG/obfuscated, not plain WireGuard.
- Current SG production state already matches this working shape server-side and DB-side:
  - `/etc/amnezia/amneziawg/wg0.conf`: `ListenPort=4500`, `MTU=1280`, `Jc=4,Jmin=5,Jmax=60`, no explicit `S/H/I` lines;
  - `servers.graniwg_obfuscation_key` for SG is `{"Jc":4,"Jmin":5,"Jmax":60}`;
  - backend-generated SG client config contains J-only params and endpoint `149.28.139.231:4500`.
- Next GRANI-app implication:
  - If GRANI still fails after fresh SG config fetch, focus on whether the embedded Android runner is actually using the AmneziaWG backend/mode for this config, not falling back to plain WireGuard semantics;
  - no APK build yet unless explicitly requested, but the next app test should fully disconnect, reopen/refresh/select Singapore, and connect so it fetches the bumped J-only config revision.

## 2026-06-10 13:58 UTC - GRANI vs AmneziaVPN obfuscation mismatch: explicit default H1-H4 applied

- User correctly challenged the previous assumption that GRANI obfuscation is identical to AmneziaVPN. New evidence:
  - AmneziaVPN manual J-only config works only after the app asks whether obfuscation is needed and the user enables it;
  - GRANI app with the same apparent J-only text config still gets only tiny packet counts.
- Code inspection of GRANI Android path:
  - `SimpleAmneziaWgRunner.kt` uses `org.amnezia.awg.backend.GoBackend` and `Config.parse`, then `setState(..., parsedConfig)`;
  - there is no explicit “enable obfuscation” switch equivalent to AmneziaVPN import checkbox;
  - `Interface.java` parser keeps every AWG parameter as `Optional`; defaults for `J/H/S/I` are `Optional.empty()`;
  - `Interface.toAwgUserspaceString()` passes only fields present in text config to `awg-go` (`jc/jmin/jmax/h1/h2/h3/h4/...`);
  - therefore a text config with only `Jc/Jmin/Jmax` does not explicitly pass `h1=1,h2=2,h3=3,h4=4` to GRANI embedded `awg-go`.
- SG server runtime when J-only config is loaded displays default headers:
  - `h1=1,h2=2,h3=3,h4=4`;
  - this is likely what AmneziaVPN enables/assumes when user checks obfuscation on import.
- Conclusion:
  - The earlier statement that GRANI and AmneziaVPN obfuscation are identical was not justified.
  - The practical mismatch is likely missing explicit default `H1-H4` on the GRANI client config path.
- Action taken server-side, no APK build:
  - backup created: `/etc/amnezia/amneziawg/wg0.conf.bak-202606101355-explicit-default-h`;
  - SG production `/etc/amnezia/amneziawg/wg0.conf` now explicitly contains:
    - `Jc=4,Jmin=5,Jmax=60`;
    - `H1=1,H2=2,H3=3,H4=4`;
    - still no `S1-S4` and no `I1-I5`;
  - SG `wg0` restarted successfully; runtime confirms `jc=4,jmin=5,jmax=60,h1=1,h2=2,h3=3,h4=4`;
  - DB `servers.graniwg_obfuscation_key` for SG updated to `{"Jc":4,"Jmin":5,"Jmax":60,"H1":"1","H2":"2","H3":"3","H4":"4"}`;
  - active SG peer revisions bumped with `sg-explicit-default-h-202606101355`.
- Verification:
  - backend-generated SG config for `rail.tamaew@gmail.com` device now includes explicit `H1=1,H2=2,H3=3,H4=4` plus `Jc=4,Jmin=5,Jmax=60`, endpoint `149.28.139.231:4500`, `MTU=1280`;
  - Docker containers are up, `granivpn_api` healthy.
- Note:
  - latest observed GRANI connection before this fix fetched config at `13:45:18 UTC`, before explicit H1-H4 were added; it later verified false with `stale_or_missing_handshake`, `rx=1716`, `tx=36606`.
  - A new disconnect/connect after this timestamp is required to test the explicit default H fix.

## 2026-06-10 14:05 UTC - v24 AAB retest still fails; issue is GRANI embedded AmneziaWG behavior, not stale server config

- User retested GRANI app on the same account `rail.tamaew@gmail.com` after SG explicit `H1-H4` server-side fix; result unchanged, only ~45 packets / no working internet.
- Fresh API/runtime check:
  - config issued after explicit H fix: `13:53:37 UTC`, `user_id=1`, `server_id=8`, `protocol=graniwg`;
  - session start: `13:53:46 UTC`, device UUID `bac13f06-2c56-4263-83d3-d72646093e54`, session `9914d90e-5256-4561-903e-62504c27bdce`;
  - generated SG config now contains `Jc=4,Jmin=5,Jmax=60,H1=1,H2=2,H3=3,H4=4`, endpoint `149.28.139.231:4500`, MTU `1280`;
  - SG runtime for peer `lpfQ0Etc...sbIpnVM=`: endpoint `94.180.243.40:41264`, latest handshake ~1m44s ago, only `1.68 KiB received / 30.22 KiB sent`;
  - `wg0` counters tiny with errors: RX `1716 bytes / 13 packets / 4 errors`, TX `30948 bytes / 117 packets / 78 errors`.
- User clarified installed app is Google Play/AAB version 24, not an old sideloaded APK.
- Project check confirms current release metadata/artifact:
  - `android/local.properties`: `flutter.versionName=1.0.4`, `flutter.versionCode=24`;
  - `build/app/outputs/bundle/release/app-release.aab` dated Jun 9, size ~74M;
  - AAB contains `base/lib/arm64-v8a/libwg-go.so`, `libwg.so`, `libwg-quick.so`;
  - extracted AAB `libwg-go.so` contains `go1.24.4` and `github.com/amnezia-vpn/amneziawg-go v0.2.16`.
- Code path check:
  - Flutter `SimpleVpnController` uses `NativeVpnService.connectAmneziaWg` when `config.engine == 'amneziawg'` or `config.configType == 'amneziawg'`;
  - `VpnPlugin.connectAmneziaWg` calls `SimpleAmneziaWgRunner.connect`;
  - `SimpleAmneziaWgRunner` uses `org.amnezia.awg.backend.GoBackend` + `Config.parse` + `setState(...UP...)`;
  - so this is not an Xray/plain backend fallback.
- Current conclusion:
  - Server-side SG production now matches the manually working J/H-default shape as closely as text config allows;
  - official AmneziaVPN with user-enabled obfuscation works, while GRANI v24 embedded AmneziaWG with equivalent explicit config still does not;
  - therefore the remaining issue is in GRANI Android embedded AmneziaWG behavior/lifecycle/integration, not stale config, wrong server_id, auth, Cloudflare, UFW/NAT, or AAB age.
- Important next direction:
  - stop changing random SG server ports/profiles;
  - compare GRANI embedded AmneziaWG runtime behavior against official AmneziaVPN import flow. The likely missing piece is not just config text fields but an app-side obfuscation mode/initialization/path that AmneziaVPN enables when the user checks “obfuscation”.
  - Any fix here will require Android/client code changes and a new AAB/APK build; server-only fixes have reached their useful limit for this symptom.

## 2026-06-10 14:18 UTC - Android AmneziaWG normalization/diagnostics implemented and APK built

- User explicitly requested to implement the listed Android-side checks/fixes and build APK.
- Changed Android AmneziaWG client path:
  - `/opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/SimpleAmneziaWgRunner.kt`;
  - `/opt/grani/mobile-app/android/third_party/amneziawg-android/tunnel/src/main/java/org/amnezia/awg/backend/GoBackend.java`;
  - `/opt/grani/mobile-app/android/third_party/amneziawg-android/tunnel/src/main/java/org/amnezia/awg/config/Interface.java`.
- `SimpleAmneziaWgRunner.kt` changes:
  - added `normalizeAmneziaObfuscation()` before `Config.parse()`;
  - for every embedded AmneziaWG connect, if `[Interface]` is missing default obfuscation fields, it now inserts missing defaults:
    - `Jc=4`, `Jmin=5`, `Jmax=60`;
    - `H1=1`, `H2=2`, `H3=3`, `H4=4`;
  - existing server-provided custom values are preserved and not overwritten;
  - added `connect: final config summary ...` log showing non-secret effective config fields after split-tunnel processing and before parse.
- `Interface.java` changes:
  - `toAwgUserspaceString()` now has a lower-level safety net: if AmneziaWG obfuscation fields are present but `H1-H4` are absent, it emits default userspace `h1=1`, `h2=2`, `h3=3`, `h4=4`;
  - this protects J-only profiles such as Sweden/SG even if the text config arrives without explicit H defaults.
- `GoBackend.java` changes:
  - before `awgTurnOn(...)`, logs redacted userspace config via `awg userspace config before turn on:`;
  - after successful `awgTurnOn(...)`, reads `awgGetConfig(currentTunnelHandle)` and logs redacted runtime config via `awg runtime config after turn on:`;
  - redaction hides `private_key` and `preshared_key`, and shortens `public_key`.
- Verification before build:
  - `dart format lib/simple_vpn/simple_vpn_controller.dart lib/services/native_vpn_service.dart` completed, 0 changed;
  - targeted `flutter analyze lib/simple_vpn/simple_vpn_controller.dart lib/services/native_vpn_service.dart --no-fatal-infos --no-fatal-warnings` completed; only 4 existing info-level `use_super_parameters` messages in `native_vpn_service.dart`;
  - APK classes checked after build and contain new diagnostic strings: `obfuscation normalize`, `connect: final config summary`, `awg userspace config before turn on`, `awg runtime config after turn on`.
- Build:
  - command: `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release`;
  - Flutter: `3.38.3`, Dart `3.10.1`;
  - build succeeded in ~352s;
  - server APK: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
  - local copied output: `outputs/grani-vpn-v24-awg-diagnostics.apk`;
  - server SHA256: `cecb6383d28b328379155576a69cc1b0d1068be4f334e87cb445be3de21feabe`;
  - size shown by Flutter: `96.1MB` (server `ls` rounds to `92M`).
- Test notes for next run:
  - Install `outputs/grani-vpn-v24-awg-diagnostics.apk`.
  - Use account `rail.tamaew@gmail.com`, select Singapore, connect.
  - If traffic still fails, collect logcat filtered by `SimpleAmneziaWG`, `AmneziaWG/GoBackend`, `awg userspace config before turn on`, `awg runtime config after turn on`.
  - The logs should now prove whether `jc/jmin/jmax/h1-h4` are really passed into embedded `awg-go` and whether `awg-go` applied them after `awgTurnOn`.

## 2026-06-10 15:32 UTC - Osaka retest after UFW disabled still fails; Sweden/Osaka runtime comparison

- User retested Osaka after UFW was disabled; result remained the same: tunnel connects, but useful incoming traffic is effectively absent.
- Backend/runtime evidence for the retest:
  - config issued for server_id=9 at 15:26:15 UTC;
  - session start 15:26:15 UTC, stop 15:26:55 UTC;
  - verify at 15:26:56 UTC: erified=True, handshake_age=39, x=2952, 	x=31630;
  - Osaka wg0 peer had endpoint 94.180.243.40:49412, transfer only ~2.88 KiB received / 42.41 KiB sent;
  - wg0 link counters: RX 2952 bytes / 26 packets, TX 43431 bytes / 356 packets, no wg0 errors;
  - UFW inactive, FORWARD allows wg0, NAT 10.0.0.0/24 -> enp1s0 present.
- Sweden vs Osaka host comparison:
  - both are Ubuntu 26.04 LTS with AmneziaWG kernel module ersion=1.0.0, srcversion=81198FA101631BF9D6CB5CB;
  - both use mneziawg-tools v1.0.20210914;
  - both wg0 interfaces are MTU 1420 and expose Jc=4,Jmin=5,Jmax=60,H1=1,H2=2,H3=3,H4=4;
  - both have IPv4 forwarding enabled and UFW inactive;
  - default NIC/offload shape is similar (	so/gso/gro on, x-udp-gro-forwarding off).
- Remaining visible differences:
  - Sweden is Veesp 13.140.9.211, default NIC th0, /24, has Docker/Amnezia traces (docker0, mn0, Docker FORWARD chains);
  - Osaka is Vultr 66.245.219.118, default NIC np1s0, /23, clean host without Docker/amn0;
  - Sweden production peer shows large traffic (MiB RX / 100+ MiB TX), Osaka production peer remains only KiB-level.
- Conclusion update:
  - the Ubuntu 24 / newer DKMS-module hypothesis is now weakened because Osaka uses the Sweden-like Ubuntu 26 + AWG module/tools and still fails in GRANI;
  - current symptom is a fresh handshake with tiny counters, not a total handshake failure;
  - next decisive split test is a manual AmneziaVPN profile against the same Osaka wg0.
- Created manual Osaka AmneziaVPN test peer:
  - peer IP 10.0.0.200/32;
  - endpoint 66.245.219.118:51820;
  - J/H params Jc=4,Jmin=5,Jmax=60,H1=1,H2=2,H3=3,H4=4;
  - config generated on server: /tmp/osaka-manual-amnezia-test-20260610-152937.conf;
  - local copy: outputs/osaka-manual-amnezia-test-20260610-152937.conf.

## 2026-06-10 15:38 UTC - Manual Osaka profile imported without obfuscation behaves as plain WireGuard and fails

- User imported the generated Osaka manual profile into AmneziaVPN and deliberately did not enable obfuscation when the app asked.
- Result: connection comes up, but traffic is tiny (~779 bytes / 5 received packets on Android VPN dialog), matching the failing GRANI/new-node symptom.
- Interpretation:
  - importing an .conf into AmneziaVPN without enabling obfuscation is effectively a plain WireGuard test, even if the text profile contains AmneziaWG-looking J/H parameters;
  - this confirms plain WireGuard shape is not sufficient on this path/provider/network;
  - next useful manual test must be the same Osaka profile with AmneziaVPN obfuscation enabled, to compare true AmneziaWG behavior against GRANI embedded AWG.

## 2026-06-10 15:42 UTC - Osaka manual AmneziaVPN with obfuscation works

- User imported the same Osaka manual profile into official AmneziaVPN and enabled obfuscation when prompted.
- Result: traffic works immediately; Android VPN dialog after ~5 seconds showed received traffic 42550 bytes / 102 packets, sent 21733 bytes / 133 packets.
- This is the decisive split:
  - same Osaka server, same endpoint/port, same wg0, same peer family;
  - without AmneziaVPN obfuscation toggle: behaves like plain WireGuard and fails with tiny received packets;
  - with AmneziaVPN obfuscation toggle: useful traffic works.
- Conclusion:
  - provider/port/basic server routing are not the primary blocker for Osaka;
  - GRANI must be fixed so its Android embedded path truly starts AmneziaWG/obfuscated mode, not a WireGuard-compatible/plain path with ignored or incomplete AWG parameters.
- Next work item:
  - inspect backend-generated config and Android AmneziaWG parser/runner to find why GRANI config is not equivalent to AmneziaVPN's obfuscated import mode;
  - stop treating this as a port/provider problem.

## 2026-06-10 15:55 UTC - Sweden config inspection and explicit AmneziaWG config fix

- User asked to inspect what the Sweden node accepts and what backend gives to clients.
- Sweden node /etc/amnezia/amneziawg/wg0.conf before persistence fix:
  - [Interface] had Address=10.0.0.1/24, ListenPort=51820, MTU=1420, Jc=4, Jmin=5, Jmax=60;
  - no explicit H1-H4 in the file;
  - peers accepted: 10.0.0.2/32, 10.0.0.3/32, 10.0.0.4/32.
- Sweden runtime wg show wg0:
  - interface exposes jc=4, jmin=5, jmax=60, h1=1, h2=2, h3=3, h4=4;
  - active production peer zlyM4MV2... had recent handshake and large traffic (MiB RX, 100+ MiB TX), so Sweden is true working AWG runtime despite J-only config file.
- Backend generator issue/fix:
  - backend services/wireguard_manager.py formatted AWG params only from DB/server config and relied on app/runtime defaults for missing H1-H4;
  - changed generator so every obfuscation_type='amneziawg' profile is normalized with explicit defaults: Jc=4,Jmin=5,Jmax=60,H1=1,H2=2,H3=3,H4=4 unless server-specific values override them;
  - AWG params now emit in stable order: Jc,Jmin,Jmax,S1-S4,H1-H4,I1-I5.
- DB updated for active AWG nodes:
  - SE-STO-01 id=5: graniwg_obfuscation_type='amneziawg', key { Jc:4,Jmin:5,Jmax:60,H1:1,H2:2,H3:3,H4:4};
  - SG-SIN-01 id=8: same explicit J/H key;
  - JP-OSA-01 id=9: same explicit J/H key.
- Persistence on nodes:
  - Sweden /etc/amnezia/amneziawg/wg0.conf updated to include explicit H1=1,H2=2,H3=3,H4=4; runtime was not restarted;
  - Osaka /etc/amnezia/amneziawg/wg0.conf updated to include explicit H1=1,H2=2,H3=3,H4=4; runtime was not restarted;
  - Singapore node file was not edited because management SSH key from grani-do is currently rejected; backend DB/generator still now issue explicit H fields for SG clients.
- Verification:
  - docker exec granivpn_api python -m py_compile /app/services/wireguard_manager.py passed;
  - granivpn_api restarted and became healthy;
  - /api/health healthy, 	otal_servers=4, healthy=4;
  - post-restart Sweden verify log stayed healthy: server_id=5 verified=True, large RX/TX counters.
- Important interpretation:
  - manual Osaka profile without AmneziaVPN obfuscation behaves as plain WireGuard and fails;
  - same Osaka profile with AmneziaVPN obfuscation enabled works;
  - therefore configs must be treated as explicit AmneziaWG profiles, not plain WG plus optional comments/defaults.

## 2026-06-10 16:17 UTC - Osaka production PSK support added and current peer updated

- User asked to finish the PresharedKey fix after manual Osaka AmneziaVPN profile with PSK worked while GRANI production profile without PSK failed.
- Implemented backend/server-only PSK support:
  - services/simple_vpn_entitlement.py: device_server_peers now has preshared_key VARCHAR via ALTER TABLE ... ADD COLUMN IF NOT EXISTS;
  - pi/simple_vpn.py: prepared peer select/upsert now carries preshared_key;
  - pi/simple_vpn.py: added per-server flag server_specs.graniwg_use_preshared_key; if enabled, missing PSK is generated and the server peer is rewritten;
  - services/wireguard_manager.py: create_client_config/create_graniwg_client_config/add_peer_to_server accept optional preshared_key and emit PresharedKey = ... in client/server peer blocks;
  - infrastructure/external/remote_vpn_manager.py: dd_wireguard_peer(..., preshared_key=...) writes PresharedKey into remote wg0.conf peer block.
- Enabled PSK only for Osaka:
  - servers.id=9 (JP-OSA-01) server_specs.graniwg_use_preshared_key=true;
  - Sweden remains without PSK because it is the working control node.
- Updated current user/device Osaka peer:
  - current device 96f15f4-9622-4bf5-a526-72d0b49f32ab, public key prefix zlyM4MV2...;
  - Osaka prepared peer 10.0.0.2/32 now has PSK in DB and on server runtime;
  - fixed one transient script mistake that had written a bogus peer with the server public key; removed it and rewrote the correct zlyM4MV2... peer with PSK.
- Verification:
  - py_compile passed for pi/simple_vpn.py, services/wireguard_manager.py, infrastructure/external/remote_vpn_manager.py, services/simple_vpn_entitlement.py;
  - granivpn_api restarted and is healthy;
  - Osaka /etc/amnezia/amneziawg/wg0.conf now has two peers:
    - manual Amnezia test 10.0.0.200/32 with PSK;
    - production GRANI peer 10.0.0.2/32 with PSK;
  - Osaka runtime wg show wg0 confirms production peer zlyM4MV2... has preshared key: (hidden);
  - backend-generated config shape now differs intentionally:
    - Sweden: no PresharedKey;
    - Osaka: includes PresharedKey in [Peer].
- Testing note:
  - phone must fetch a fresh Osaka config after this timestamp; old local app cache may still contain the no-PSK Osaka config.
  - safest test: fully disconnect, clear app data or otherwise force fresh config, log in, select Osaka, connect.

## 2026-06-10 16:20 UTC - Exported current GRANI-style Amnezia configs for user 1

- User asked for two AmneziaVPN import configs showing how GRANI service currently creates profiles for Sweden and Osaka.
- Exported from live backend data for user_id=1, current device DB id 237, device UUID b96f15f4-9622-4bf5-a526-72d0b49f32ab.
- Generated full configs inside API container and copied to local outputs:
  - outputs/grani-se-sto-01-user1-device237.conf;
  - outputs/grani-jp-osa-01-user1-device237.conf.
- Redacted shape:
  - both have MTU=1420, Jc=4, Jmin=5, Jmax=60, H1=1, H2=2, H3=3, H4=4;
  - Sweden: Address=10.0.0.3/32, endpoint 13.140.9.211:51820, no PresharedKey;
  - Osaka: Address=10.0.0.2/32, endpoint 66.245.219.118:51820, includes PresharedKey.

## 2026-06-10 16:27 UTC - Simple VPN device auto-create fallback after Osaka PSK test still did not reach config

- User retested after Osaka PSK support; reported Sweden connects, Osaka does not.
- Logs showed the Osaka attempt did not actually receive an Osaka config after the PSK fix:
  - successful fresh Sweden flow: config issued for server_id=5 at 16:20:14 UTC, session start, verify true;
  - after that, repeated /api/simple-vpn/config calls failed with 409 DEVICE_NOT_REGISTERED;
  - failing device id in status/config path included 598e8ed-5ff2-4346-b37d-8a0f5ab6ae57, while the working GRANIwg session/device was 96f15f4-9622-4bf5-a526-72d0b49f32ab.
- Interpretation:
  - current Osaka test failure after PSK was blocked before tunnel/config validation by device-registration mismatch/cache pipeline;
  - no simple-vpn config issued server_id=9 appeared after the PSK fix during that retest.
- Server-only mitigation implemented:
  - pi/simple_vpn.py::_simple_device() no longer returns 409 DEVICE_NOT_REGISTERED for an authenticated user with a new Simple VPN device_id;
  - it now auto-creates a minimal active Android Device record and then the normal Simple VPN path generates WireGuard/AWG keys and prepared peer;
  - this is a fallback for app reinstall/reauth/device-id drift and avoids blocking config issuance.
- Verification:
  - docker exec granivpn_api python -m py_compile /app/api/simple_vpn.py passed;
  - granivpn_api restarted and is healthy.
- Next expected log after user retries Osaka:
  - either simple-vpn auto-created missing device ... followed by simple-vpn config issued server_id=9, or direct simple-vpn config issued server_id=9 if device is already registered.

## 2026-06-10 16:45 UTC - Real issued configs and node-accepted configs checked for Sweden vs Osaka

- User reported Osaka connected in GRANI but received packets stayed tiny (Android dialog: ~484 bytes / 5 packets after 7s).
- Checked real DB/API production config for user_id=1, device DB id 237, UUID b96f15f4-9622-4bf5-a526-72d0b49f32ab:
  - device public key: zlyM4MV2... sha256 d37b81608b37;
  - device private key fingerprint: sha256 03f0f2aee5a5;
  - Sweden issued config: Address 10.0.0.3/32, endpoint 13.140.9.211:51820, Jc=4,Jmin=5,Jmax=60,H1=1,H2=2,H3=3,H4=4, no PresharedKey;
  - Osaka issued config: Address 10.0.0.2/32, endpoint 66.245.219.118:51820, same J/H params, PresharedKey present with fingerprint sha256 c05a0ddf5e06.
- Checked real node files and runtime through backend SSH credentials:
  - Sweden /etc/amnezia/amneziawg/wg0.conf has Interface MTU 1420, J/H params, NAT 10.0.0.0/24 -> eth0, peer zlyM4MV2... AllowedIPs 10.0.0.3/32;
  - Sweden runtime: same peer zlyM4MV2... endpoint 94.180.243.40:39599, latest handshake ~40s, transfer ~14.44 MiB received / 272.92 MiB sent;
  - Osaka /etc/amnezia/amneziawg/wg0.conf has Interface MTU 1420, J/H params, NAT 10.0.0.0/24 -> enp1s0, production peer zlyM4MV2... AllowedIPs 10.0.0.2/32 with PresharedKey fingerprint c05a0ddf5e06, plus separate manual test peer +XLAbwMv... 10.0.0.200/32 with PSK;
  - Osaka runtime: production peer zlyM4MV2... has preshared key, endpoint 94.180.243.40:46977, latest handshake ~11 min after test, transfer only ~4.37 KiB received / 51.81 KiB sent;
  - Osaka wg0 link counters after GRANI test: RX 4476 bytes / 36 packets / 9 errors, TX 53051 bytes / 246 packets / 0 errors.
- Conclusion from real configs:
  - this is not stale app cache and not the wrong node/peer: backend-issued Osaka config matches the production peer accepted by Osaka runtime;
  - backend text config includes AWG J/H params and PSK, and node runtime has matching peer/PSK;
  - remaining failure is after handshake/useful-traffic stage. Since manual AmneziaVPN obfuscated import on Osaka worked while GRANI production peer does not, next likely layer is GRANI Android embedded AmneziaWG runtime/plumbing or split-tunnel/routing behavior, not server config identity.

## 2026-06-10 16:50 UTC - Fresh Osaka production config exported for AmneziaVPN split test

- Created fresh Osaka production client config from live DB for user_id=1, device DB id 237, UUID b96f15f4-9622-4bf5-a526-72d0b49f32ab.
- Source data:
  - server JP-OSA-01 id=9, endpoint 66.245.219.118:51820;
  - client Address 10.0.0.2/32;
  - Jc=4,Jmin=5,Jmax=60,H1=1,H2=2,H3=3,H4=4;
  - PresharedKey included.
- Host copy: /tmp/grani-jp-osa-production-device237-amnezia-test.conf.
- Local copy for user import: outputs/grani-jp-osa-production-device237-amnezia-test.conf.
- Purpose: import this exact GRANI production Osaka profile into official AmneziaVPN and enable obfuscation. If it works there, the server/profile is valid and the GRANI Android embedded AmneziaWG runtime/plumbing is the failing layer. If it also fails there, recreate the production Osaka peer/key/IP/PSK on the server.

## 2026-06-10 16:55 UTC - Decisive split test: exact GRANI Osaka production config works in official AmneziaVPN

- User imported outputs/grani-jp-osa-production-device237-amnezia-test.conf into official AmneziaVPN and enabled obfuscation when prompted.
- Result: connection works; normal traffic passes.
- This config is the exact GRANI production Osaka profile for device DB id 237:
  - Address 10.0.0.2/32;
  - endpoint 66.245.219.118:51820;
  - same client private/public key as GRANI device;
  - same server public key;
  - same PresharedKey as Osaka production peer;
  - same Jc/Jmin/Jmax/H1-H4 values as backend-issued GRANI config.
- Conclusion is now decisive:
  - Osaka server, routing/NAT, production peer, client key, server key, PSK and backend-generated text config are valid;
  - failure is in GRANI Android client runtime/plumbing, not server-side config identity;
  - stop changing ports/providers/peer keys as primary fix;
  - next implementation target: Android embedded AmneziaWG path in mobile-app, especially SimpleAmneziaWgRunner/third_party amneziawg-android GoBackend/userspace runtime, socket protection/VpnService routing, or version mismatch vs official AmneziaVPN AmneziaWG v2 behavior.

## 2026-06-10 17:08 UTC - Android GRANIwg runner patched to start full-tunnel config unchanged

- After decisive split test, exact Osaka production profile works in official AmneziaVPN with obfuscation, but fails in GRANI. Server/nodes/backend are no longer the primary suspect.
- Changed mobile-app Android runner:
  - file: /opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/SimpleAmneziaWgRunner.kt;
  - added FORCE_GRANIWG_FULL_TUNNEL=true;
  - GRANIwg path now returns the normalized AWG config unchanged from applySplitTunnelPrefs(), instead of applying native app/domain split tunnel mutations before Config.parse()/GoBackend.setState();
  - if app packages or direct domains exist in SharedPreferences, runner logs that split tunnel is ignored for GRANIwg stability;
  - final config summary now reports PresharedKey=(present) without leaking the key.
- Rationale:
  - official AmneziaVPN test proved the production Osaka config works when imported as an obfuscated AWG full-tunnel profile;
  - GRANI previously could rewrite AllowedIPs/app routing based on native SplitTunnelPrefs before starting AmneziaWG, creating a runtime profile different from the tested .conf;
  - this patch makes GRANIwg runtime closer to the proven working official AmneziaVPN import path.
- Verification:
  - cd /opt/grani/mobile-app/android && ./gradlew :app:compileDebugKotlin -> BUILD SUCCESSFUL;
  - cd /opt/grani/mobile-app && /opt/flutter/bin/flutter analyze android/app/src/main/kotlin/com/granivpn/mobile/SimpleAmneziaWgRunner.kt --no-fatal-infos --no-fatal-warnings -> No issues found.
- APK was not built; mobile change reaches a device only after the next explicit APK build.

## 2026-06-10 17:18 UTC - Compared official Amnezia auto-obfuscation profile vs GRANI Osaka profile

- User provided an Amnezia vpn:// link. It decodes as: first 4 bytes prefix, then zlib-compressed JSON; defaultContainer=amnezia-awg2, hostName=167.233.66.144.
- Recreated config locally: outputs/amnezia-vpn-link-recreated.conf; redacted decoded JSON: outputs/amnezia-vpn-link-decoded-redacted.json.
- Compared this official Amnezia auto-obfuscation profile with GRANI Osaka production config outputs/grani-jp-osa-production-device237-amnezia-test.conf.
- Important obfuscation differences:
  - Amnezia auto: Jc=5, Jmin=10, Jmax=50; GRANI Osaka: Jc=4, Jmin=5, Jmax=60.
  - Amnezia auto has S1=138,S2=20,S3=35,S4=13; GRANI Osaka has no S1-S4.
  - Amnezia auto has H1-H4 as large randomized ranges:
    - H1=1065396326-1762624561;
    - H2=1938780048-1988422668;
    - H3=2118021394-2124378345;
    - H4=2132846382-2134177661.
  - GRANI Osaka has dummy/simple H1=1,H2=2,H3=3,H4=4.
  - Amnezia auto has I1 payload: <r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>; GRANI Osaka has no I1-I5.
  - Amnezia auto includes IPv6 AllowedIPs (::/0); GRANI Osaka is IPv4-only 0.0.0.0/0.
- Interpretation:
  - GRANI currently does not generate a true Amnezia auto-obfuscation/v2-style parameter set; it uses minimal J/H defaults that are AWG-looking but much weaker/different than official Amnezia generated profiles.
  - This is now a strong candidate for why official AmneziaVPN profiles behave differently from GRANI on hostile/mobile paths.
  - Next server-only experiment candidate: apply an Amnezia-style generated J/S/H/I parameter set to one failing test node (Osaka), update backend server graniwg_obfuscation_key and node /etc/amnezia/amneziawg/wg0.conf consistently, then issue fresh GRANI config and retest. This does not require APK if current embedded parser accepts S/H ranges/I fields.

## 2026-06-10 - Primary-source notes: how Amnezia creates AWG/AWG2 configs

- Source checked from official `amnezia-vpn/amnezia-client` repository cloned at `/tmp/amnezia-src/amnezia-client`.
- Amnezia does not create AWG/AWG2 configs from one fixed static template only. During `AwgInstaller::generateConfig(...)`, it detects `DockerContainer::Awg2`, calls `generateAwgParameters(...)`, and sets `serverConfig.protocolVersion = "2"` for AWG2.
- `generateAwgParameters(...)` generates:
  - `Jc` as random integer in `[4, 6]`, `Jmin=10`, `Jmax=50`;
  - `S1/S2` random in `[15,149]`, `S3` random in `[0,63]`, `S4` random in `[0,19]`, with uniqueness/packet-size collision checks;
  - for AWG2, `H1-H4` are ordered random ranges like `first-second`, not simple constants;
  - for legacy AWG, `H1-H4` are random single integer values;
  - `I1-I5` are filled from protocol constants, with `I1` defaulting to the special junk DNS-like payload and `I2-I5` empty by default.
- `scriptsRegistry.cpp` maps these generated serverConfig values into script/template variables: `$JUNK_PACKET_COUNT`, `$INIT_PACKET_JUNK_SIZE`, `$INIT_PACKET_MAGIC_HEADER`, `$SPECIAL_JUNK_1`, etc.
- `client/server_scripts/awg/template.conf` shows the actual native client config fields Amnezia expects: `Jc/Jmin/Jmax`, `S1-S4`, `H1-H4`, `I1-I5`, then peer `PresharedKey`, `AllowedIPs = 0.0.0.0/0, ::/0`, endpoint and keepalive.
- Amnezia share links are generated as `vpn://` + `qCompress(JSON, 8)` + base64url without trailing equals. Import reverses this with base64url decode + `qUncompress`.
- Android Amnezia official client parses `isObfuscationEnabled`; if true it enables protocol extension and applies `Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5`; it also parses optional `psk_key` into `preshared_key`.
- Implication for GRANI: current minimal GRANI profiles with only `Jc/Jmin/Jmax` and dummy `H1-H4=1..4` are not equivalent to Amnezia's self-hosted AWG2 auto-generated profile. To match Amnezia, GRANI backend/server provisioning must persist a full per-server AWG2 obfuscation profile (`J/S/H/I`, PSK policy, full-tunnel allowed IPs) and issue exactly the same values to client and node.

## 2026-06-10 17:25 UTC - Osaka converted to full AmneziaWG v2-style profile

- User asked to make GRANI configs "one-to-one" with official AmneziaWG v2 generation.
- Backend changes:
  - `services/wireguard_manager.py` now has `generate_amneziawg_v2_params()` matching Amnezia installer ranges:
    - `Jc` random `[4,6]`, `Jmin=10`, `Jmax=50`;
    - `S1/S2` random `[15,149]`, `S3` `[0,63]`, `S4` `[0,19]`, with the same packet-size collision checks using message sizes 148/92/64;
    - AWG2 `H1-H4` generated as ordered random ranges, not dummy constants;
    - `I1` uses Amnezia default special junk payload, empty `I2-I5` are omitted when formatting text configs because `awg` on the node rejects empty lines like `I2 =`.
  - GRANIwg client config now uses Amnezia-like DNS and routing:
    - `DNS = 1.1.1.1, 1.0.0.1`;
    - `AllowedIPs = 0.0.0.0/0, ::/0`.
  - `infrastructure/external/wireguard_manager.py` formatter was synchronized for stable AWG param order and skipping empty `I*` values.
- Osaka DB update:
  - server id `9` / `JP-OSA-01` now has full `graniwg_obfuscation_key`:
    - `Jc=4,Jmin=10,Jmax=50`;
    - `S1=20,S2=120,S3=54,S4=5`;
    - `H1=99602355-1218988358`;
    - `H2=1295926850-1400171950`;
    - `H3=1431419187-1750092792`;
    - `H4=2041284904-2066794259`;
    - `I1=<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>`;
    - `I2-I5` empty in DB but omitted from emitted config text.
- Osaka node update:
  - updated `/etc/amnezia/amneziawg/wg0.conf` `[Interface]` with the same full AWG2 values;
  - backup created on node: `/etc/amnezia/amneziawg/wg0.conf.bak-awg2-20260610172310`;
  - first restart failed because the node parser rejected empty `I2 =`; after omitting empty `I2-I5`, restart succeeded;
  - `systemctl is-active awg-quick@wg0` -> `active`;
  - `awg show wg0` shows runtime `jc/jmin/jmax/s1-s4/h1-h4/i1` matching DB/client config;
  - production peer `zlyM4MV2...` remains present with PSK and `AllowedIPs 10.0.0.2/32`.
- Verification:
  - `docker exec granivpn_api python -m py_compile /app/services/wireguard_manager.py /app/infrastructure/external/wireguard_manager.py /app/api/simple_vpn.py` passed;
  - `granivpn_api` restarted and is healthy;
  - redacted generated Osaka config for device 237 now contains full `J/S/H/I1`, `PresharedKey=(present)`, endpoint `66.245.219.118:51820`, DNS `1.1.1.1, 1.0.0.1`, and `AllowedIPs = 0.0.0.0/0, ::/0`.
- Sweden was intentionally not changed and remains the working control node.
- APK was not built in this step.
- Next phone test:
  - fully disconnect VPN;
  - force fresh Osaka config (clear app data or re-login if cache is suspected);
  - choose Osaka and connect;
  - expected Android config should contain full AWG2 fields rather than old `H1=1,H2=2,H3=3,H4=4` minimal profile.

## 2026-06-10 17:40 UTC - Retest after full Osaka AWG2 profile still fails in GRANI

- User retested Osaka after converting server/backend to full AmneziaWG v2-style profile. Result remained the same: GRANI connects but useful incoming traffic does not pass.
- Live Osaka state during/after test:
  - `awg-quick@wg0` is active;
  - runtime still shows full AWG2 params: `Jc=4,Jmin=10,Jmax=50,S1=20,S2=120,S3=54,S4=5,H1-H4` ranges and `I1` special junk;
  - production peer `zlyM4MV2...` endpoint `178.176.86.31:46669`, latest handshake about 2 minutes old;
  - transfer remained tiny: about `296 B received / 9.24 KiB sent`;
  - `ip -s link show wg0`: RX `296 bytes / 2 packets / 4 errors`, TX `9466 bytes / 166 packets / 0 errors`.
- Backend logs confirm fresh Osaka flow after the full AWG2 change:
  - `17:35:12 UTC` config issued for `server_id=9`;
  - `17:35:22 UTC` session start for `server_id=9`;
  - verify at `17:35:43 UTC` was technically `verified=True` but only tiny counters `rx=148 tx=249`;
  - later Osaka verify became `verified=False reason=stale_or_missing_handshake` with tiny counters `rx=296 tx=9113`.
- Redacted backend-generated Osaka config now contains the intended full profile:
  - Address `10.0.0.2/32`;
  - DNS `1.1.1.1, 1.0.0.1`;
  - `MTU=1420`;
  - full `J/S/H/I1`;
  - `PresharedKey` present;
  - endpoint `66.245.219.118:51820`;
  - `AllowedIPs = 0.0.0.0/0, ::/0`.
- Android source note:
  - `SimpleAmneziaWgRunner.kt` currently has `FORCE_GRANIWG_FULL_TUNNEL=true` and preserves full config text;
  - analyze passed for that file;
  - however APK was not built after this runner full-tunnel patch, so the user's installed APK likely does not include this client-side fix yet.
- Exported a new exact full Osaka AWG2 config for official AmneziaVPN control test:
  - host/container source: `/tmp/grani-jp-osa-full-awg2-device237-amnezia-test.conf`;
  - local output: `outputs/grani-jp-osa-full-awg2-device237-amnezia-test.conf`.
- Current interpretation:
  - server/backend/node identity is no longer the main suspect: fresh Osaka full-AWG2 config is issued and node accepts the matching runtime profile;
  - remaining likely layer is GRANI Android runtime/APK behavior, especially because the full-tunnel runner patch has not reached the device yet;
  - next decisive test: import the new full Osaka AWG2 `.conf` into official AmneziaVPN with obfuscation enabled. If it works there, build/install a new GRANI APK containing the full-tunnel runner patch and retest Osaka.

## 2026-06-10 17:46 UTC - Correction: Osaka full AWG2 works on Wi-Fi in GRANI

- User corrected the previous result: after switching/testing on Wi-Fi, Osaka in GRANI worked. Screenshot showed Android VPN dialog after ~10s:
  - sent `47448 bytes / 209 packets`;
  - received `56765 bytes / 152 packets`.
- Live Osaka check confirmed real useful traffic, not just UI state:
  - `awg-quick@wg0` active with full AWG2 params (`J/S/H/I1`);
  - production peer `zlyM4MV2...` endpoint `94.180.132.76:47642`;
  - latest handshake `16 seconds ago`;
  - transfer `1.02 MiB received / 3.51 MiB sent`;
  - link counters `RX 1,074,356 bytes / 3,250 packets`, `TX 3,678,512 bytes / 4,469 packets`.
- Backend logs also confirm healthy Osaka verify after the full AWG2 change:
  - `17:41:51 UTC` server_id=9 verified true with `rx=50548 tx=78127`;
  - `17:42:33 UTC` server_id=9 verified true with `rx=643556 tx=3187126`;
  - `17:43:33 UTC` server_id=9 verified true with `rx=930824 tx=3541224`;
  - `17:45:35 UTC` server_id=9 verified true with `rx=1033076 tx=3625843`.
- Updated interpretation:
  - Full AmneziaWG v2-style server/backend profile fixed Osaka on Wi-Fi in GRANI.
  - Remaining bad behavior is now specifically LTE/mobile-network path sensitivity, not a total Osaka/server/config failure.
  - Do not roll back the full AWG2 profile. Next work should treat LTE separately: MTU/mobile carrier behavior/handshake keepalive/client runtime/APK version, using Wi-Fi success as the working baseline.

## 2026-06-11 05:45 UTC - Current LTE-focused status after context reread

- User summarized current state:
  - Sweden works on Wi-Fi and LTE and must not be touched;
  - Osaka works on Wi-Fi but not on LTE;
  - transition from LTE to Wi-Fi behaves badly until reconnect;
  - Germany/Finland/Singapore still do not work in the old/non-full-AWG2 state;
  - official AmneziaVPN shows the same Osaka pattern: Wi-Fi works, LTE does not, so the remaining issue is not specific to GRANI UI/app only.
- Live Osaka check on 2026-06-11:
  - `awg-quick@wg0` active;
  - full AWG2 runtime still present (`J/S/H/I1`);
  - production peer `zlyM4MV2...` endpoint `94.180.243.40:47148`;
  - latest handshake ~53s;
  - accumulated transfer `92.04 MiB received / 2.58 GiB sent`;
  - Osaka has public IPv4 and public IPv6 on `enp1s0`; `wg0` has only IPv4 `10.0.0.1/24`;
  - IPv4 forwarding and IPv6 forwarding are enabled;
  - UFW inactive.
- Backend logs show long-running successful Osaka traffic on the same peer/session after Wi-Fi success, with verify alternating only because handshake age can exceed the current 60s threshold despite counters growing.
- Current interpretation:
  - Do not roll back full AWG2 Osaka profile.
  - Remaining issue is LTE/mobile-carrier path sensitivity. Since official AmneziaVPN behaves the same, the first suspects are MTU/fragmentation, IPv6/full-tunnel interaction on mobile networks, and endpoint/network-change recovery.
  - Because Osaka client config currently has `AllowedIPs = 0.0.0.0/0, ::/0` but the tunnel address is IPv4-only, one safe test candidate is to remove IPv6 full-tunnel capture for Osaka clients (`AllowedIPs = 0.0.0.0/0`) and/or lower Osaka client MTU to 1280. Sweden remains untouched.

## 2026-06-11 - User correction: MTU/port tests already tried in AmneziaVPN

- User clarified that yesterday official AmneziaVPN testing already included MTU, ports and similar transport tweaks, and they did not fix LTE.
- Therefore do not restart the same MTU/port churn as the main plan.
- Updated LTE investigation priority:
  - compare working Sweden vs failing Osaka at provider/ASN/routing/runtime/profile level;
  - test IPv6/full-tunnel capture separately only if it was not covered by the previous Amnezia tests;
  - consider that Vultr/Hetzner paths may be bad on the user's LTE carrier while Veesp Sweden path works;
  - preserve full AWG2 Osaka profile because it fixed Wi-Fi and is now the working baseline for that node.

## 2026-06-11 05:55 UTC - Sweden vs Osaka comparison: ASN, routing, IPv6, endpoint behavior

- Compared Sweden `13.140.9.211` and Osaka `66.245.219.118` without changing either node.
- ASN/provider:
  - Sweden: `AS42532 SIA VEESP`, Stockholm, SE.
  - Osaka: `AS20473 The Constant Company, LLC` / Vultr, Osaka, JP.
  - Observed Wi-Fi client endpoint: `94.180.243.40`, `AS41668 JSC ER-Telecom Holding`, Kazan/RU.
  - Observed LTE client endpoints: `178.176.86.29/31`, `AS31133 PJSC MegaFon`, RU.
- Runtime similarity:
  - Both nodes run Ubuntu `26.04 LTS`.
  - Sweden kernel `7.0.0-14-generic`, Osaka kernel `7.0.0-22-generic`.
  - Both use `amneziawg-tools v1.0.20210914`.
  - Both use amneziawg kernel module `version 1.0.0`, `srcversion 81198FA101631BF9D6CB5CB`.
  - UFW inactive on both.
  - IPv4 forwarding enabled on both.
- Runtime/config differences:
  - Sweden keeps old/minimal J/H runtime: `Jc=4,Jmin=5,Jmax=60,H1-H4=1..4`, no PSK for production peer.
  - Osaka uses full AWG2-style runtime: `Jc=4,Jmin=10,Jmax=50,S1-S4,H1-H4 ranges,I1`, PSK enabled.
  - Sweden `net.ipv6.conf.all.forwarding=0`; Osaka `net.ipv6.conf.all.forwarding=1`.
  - Both have public IPv6 on the public interface; both `wg0` are IPv4-only (`10.0.0.1/24`).
- Live endpoint/traffic observations:
  - Sweden had LTE/MegaFon endpoint `178.176.86.28:36418` with large accumulated traffic `210 MiB received / 2.63 GiB sent`; latest handshake in the sampled moment was old, but backend logs show the session alternates verified/stale by handshake age while counters keep growing.
  - Osaka had LTE/MegaFon endpoint `178.176.86.29:48924` with recent handshake and large accumulated traffic `92.53 MiB received / 2.59 GiB sent` after successful Wi-Fi use.
  - A 15s Osaka transfer delta started while endpoint was MegaFon but by the end endpoint had switched to ER-Telecom Wi-Fi `94.180.243.40:40416`; transfer grew from `97029840/2782991236` to `97446900/2783896964`, i.e. about `+417 KB RX / +906 KB TX`, consistent with Wi-Fi becoming active after endpoint switch.
- Route/latency comparison from nodes to Russian endpoints:
  - Sweden -> ER-Telecom Wi-Fi `94.180.243.40`: ping works, ~33 ms.
  - Osaka -> ER-Telecom Wi-Fi `94.180.243.40`: ping works, ~280 ms.
  - Sweden -> MegaFon `178.176.86.29/31`: ICMP ping blocked, tracepath reaches MegaFon/private route quickly with pmtu 1500.
  - Osaka -> MegaFon `178.176.86.29/31`: ICMP ping blocked, tracepath goes via Vultr/Telia-style transit and already reaches ~210-238 ms by hop 7/8, pmtu 1500.
- Interpretation:
  - The OS/kernel/AWG module layer is not the key difference; Sweden and Osaka are intentionally close there.
  - The strongest concrete difference is provider/ASN and network path to Russian LTE/Wi-Fi endpoints: Veesp Sweden has a much shorter/better path to RU networks, while Vultr Osaka has long transcontinental transit.
  - The LTE problem is therefore likely path/provider/mobile-carrier sensitivity, not another basic WireGuard field/port/MTU issue.
  - IPv6/full-tunnel capture remains a separate low-risk test candidate because Osaka clients use `AllowedIPs = 0.0.0.0/0, ::/0` while tunnel addresses are IPv4-only, but user clarified MTU/ports were already tested and should not be repeated as the main line.

## 2026-06-11 - Amnezia docs interpretation for Osaka LTE issue

- Checked official Amnezia documentation/troubleshooting for AmneziaWG.
- Docs say AmneziaWG 2.0 is designed to mask traffic as common UDP protocols; v2 adds dynamic H1-H4 ranges, S3/S4, and uses I1-I5 signatures.
- Docs also explicitly describe the exact symptom: VPN connects but no traffic/websites do not open.
- Their troubleshooting order:
  1. First check whether the same internet connection without VPN can reach foreign sites/speedtest; if not, the network may be whitelist/heavily restricted and changing internet source/provider can help.
  2. If server is unreachable over SSH/management from that same network, server IP may be blocked by carrier/ISP; solution is changing IP or hosting provider.
  3. If server is reachable but VPN traffic fails, suspect AmneziaWG parameters/signature; docs recommend testing Jc=6 and replacing I1 with their DNS-like signature.
  4. If signatures do not help, then test ports below 9999 or 443.
- Mapping to GRANI state:
  - Ports/MTU were already tested by user and did not solve LTE.
  - Osaka works on Wi-Fi in both GRANI/Amnezia, but not LTE, and Sweden works on LTE.
  - This aligns most with Amnezia docs categories: mobile carrier/network path or server IP/provider/ASN sensitivity, then signature/Jc/I1 as a targeted test, not generic port churn.

## 2026-06-11 - Checked AmneziaVPN 4.8.17.0/4.8.18.0 for protocol changes

- User showed the Amnezia Telegram announcement for app version `4.8.17.0`, which says it is an important release intended to help adapt AmneziaWG to new blocking conditions.
- Checked official GitHub release pages:
  - `4.8.17.0` release title is `fix: script remove docker volume (#2686)` and release notes only mention docker volume/script cleanup;
  - `4.8.18.0` is the latest visible release on GitHub as of 2026-06-11 and its changelog says only `General: improve stability`.
- Pulled tags in `/tmp/amnezia-src/amnezia-client` and compared AWG-related source files across `4.8.15.4`, `4.8.16.0`, `4.8.17.0`, and `4.8.18.0`.
- Important source-level findings:
  - No new AWG config fields beyond the known AWG2 set were found: `Jc/Jmin/Jmax`, `S1-S4`, `H1-H4`, `I1-I5`, `PresharedKey`, `AllowedIPs`, `MTU`, endpoint/keepalive.
  - The AWG2 generation logic in `4.8.15.4` and `4.8.18.0` is effectively the same for protocol-shaping values:
    - `Jc` random `[4,6]`, `Jmin=10`, `Jmax=50`;
    - `S1/S2` random `[15,149]`, `S3` `[1,63]`, `S4` `[1,19]` in the public client installer path;
    - ordered randomized `H1-H4` ranges;
    - same default `I1` payload: `<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>`;
    - `I2-I5` remain empty by default.
  - Android AWG bridge files (`client/android/awg/...`, `client/android/wireguard/...`, `VpnProto.kt`) have the same relevant AWG/WireGuard behavior across checked tags; no obvious native protocol-engine bump was visible in these paths.
  - `4.8.16/4.8.17` moved many files into `client/core/...`; `4.8.18` returns/uses another tree layout. The huge diff is mostly repository structure/build refactor noise, not evidence of a new AWG wire format.
- Interpretation for GRANI:
  - The Telegram wording likely means app/infrastructure/signature adaptation and stability work, not a new publicly documented AmneziaWG protocol version beyond AWG2.
  - The protocol shape we implemented for Osaka already matches the known AWG2 public-source model closely. A remaining LTE failure on Osaka is therefore more likely provider/ASN/mobile-route/signature/IP-blocking sensitivity than GRANI missing a newly introduced protocol field.
  - The one protocol-level knob still aligned with official troubleshooting is rotating AWG signature values, especially `Jc` and `I1`; but this should be treated as targeted signature testing, not as “upgrade to a new protocol version”.

## 2026-06-11 - New Amnezia version LTE test result

- User tested the updated AmneziaVPN app after the Telegram announcement about version `4.8.17.0`/new blocking conditions.
- Result: Germany connected and worked on Wi-Fi, but LTE remained dead/no useful incoming traffic.
- Interpretation:
  - The updated Amnezia app did not magically fix the LTE path.
  - The repeated pattern is now broader than Osaka: Wi-Fi can work, LTE can fail on non-Sweden nodes.
  - This further supports the hypothesis that the main remaining problem is mobile-carrier/provider/ASN/IP-route/signature sensitivity rather than a missing GRANI-only config field or old Amnezia app version.
  - Sweden remains the only confirmed node working on both Wi-Fi and LTE and should remain untouched as the control node.
## 2026-06-11 - Deeper Veesp comparison against Vultr/Hetzner

- User asked to investigate why Sweden/Veesp behaves differently from Osaka/Vultr and Hetzner DE/FI.
- Public ASN/IP facts:
  - Sweden `13.140.9.211` -> `AS42532 SIA VEESP`, Stockholm, prefix `13.140.8.0/21`.
  - Osaka `66.245.219.118` and Singapore `149.28.139.231` -> `AS20473 The Constant Company, LLC` / Vultr.
  - Germany `167.233.66.144` and Finland `204.168.160.160` -> `AS24940 Hetzner Online GmbH`.
- Veesp public network facts from BGP/HE/BGP.tools:
  - AS42532 has far fewer originated prefixes than Vultr/Hetzner and looks like a smaller regional hosting network rather than a huge global cloud ASN.
  - Veesp upstreams/major peers include RETN and Arelion; observed Veesp peer lists include RU/CIS-relevant networks such as TransTeleCom (`AS20485`), RETN Russia/JSC RetnNet (`AS57304`), VimpelCom (`AS3216`), Rostelecom (`AS12389`), RASCOM (`AS20764`), INETCOM (`AS35598`), and MegaFon (`AS31133`). Treat these as public BGP observations, not a guarantee of direct route from every location.
  - Veesp official site advertises VPS locations LV/NL/SE, unlimited traffic, 1 Gbit VPS bandwidth, public looking glasses including Sweden, and external channel capacity around 250 Gbit/s.
- Live route/latency tests from nodes:
  - Sweden/Veesp -> ER-Telecom Wi-Fi endpoint `94.180.243.40`: ping ~33 ms, trace enters RETN/RU path quickly.
  - Finland/Hetzner -> same Wi-Fi endpoint: ping ~41 ms.
  - Germany/Hetzner -> same Wi-Fi endpoint: ping ~52 ms.
  - Osaka/Vultr -> same Wi-Fi endpoint: ping ~295 ms and trace goes through Vultr private hops then Arelion/Telia-style long transit.
  - MegaFon LTE endpoint `178.176.86.29` blocks ICMP from all tested nodes, so ping is not useful there; previous VPN behavior remains the real signal.
- Interpretation:
  - Osaka/Vultr is clearly weak for Russia/LTE by distance and route length; it is a poor production candidate for RU mobile traffic even if Wi-Fi works.
  - Hetzner DE/FI is geographically closer and has low latency to the Wi-Fi endpoint, but the observed LTE failure in both official Amnezia and GRANI suggests route/IP/ASN reputation or mobile-carrier policy, not just raw latency.
  - Veesp Sweden's winning properties are likely a combination of: smaller/regional ASN, existing RU/CIS peer visibility, Stockholm/Riga-adjacent routing, and IP/prefix reputation that MegaFon currently lets pass. It is not explained by OS/kernel/AWG module because Sweden and Osaka were already close at that layer.
- Practical consequence:
  - For new working nodes, prioritize providers/locations with Veesp-like route characteristics: Nordics/Baltics/nearby Europe, smaller/regional ASN, visible peers/transit to RU/CIS networks, and preferably a public looking glass before purchase.
  - Avoid treating Vultr Osaka/Singapore as representative of protocol success/failure; they are likely bad RU LTE path candidates.
  - Hetzner may still fail on LTE despite acceptable Wi-Fi latency, so it should not be used as proof that Europe is enough.

## 2026-06-11 - Marketing geography risk note: RU LTE vs India/Indonesia/Pakistan

- User is worried that the protocol failing on RU LTE may also fail in future ad geos such as Pakistan, Indonesia, and India.
- Current interpretation:
  - RU MegaFon LTE failure does not prove global LTE failure. It proves that specific combinations of mobile carrier + ASN/IP/provider route + AWG signature can fail even when Wi-Fi works.
  - Official Amnezia behaving the same on affected nodes means this is not only a GRANI app bug.
- Country risk from public sources checked quickly:
  - Pakistan has active VPN regulation/registration/blocking pressure; VPN reliability should be treated as high-risk and carrier-specific.
  - Indonesia has public reports of national filtering/DPI across major ISPs/mobile providers; VPN protocol survivability should be tested on Telkomsel/XL/Indosat/Smartfren-like networks before scaling.
  - India has VPN/data-retention regulation pressure and history of blocks/shutdowns; protocol may work technically, but compliance/reliability risk remains.
- Operational recommendation:
  - Do not extrapolate RU LTE to all countries, but do not launch ads blindly.
  - Before paid traffic, create a country/operator test matrix: at least 2-3 real testers or device farms per country, on mobile data, with Wi-Fi off, testing login/connect/speedtest/reconnect/network switch.
  - Server adaptation cannot make Vultr/Hetzner “become Veesp”; server-side knobs can change AWG signatures, ports, MTU, DNS, IPv6/AllowedIPs, and lifecycle behavior, but ASN/IP reputation and upstream routing require provider/IP/location changes.

## 2026-06-11 - Hysteria2 standalone PoC on Germany

- User asked whether GRANI can try a simple Hysteria2 config because AWG fails on LTE for several non-Sweden nodes.
- Project search found no existing Hysteria/HY2 integration in `/opt/grani` backend/mobile/docs/server-config.
- Created a standalone Hysteria2 test on Germany/Hetzner node `167.233.66.144`; Sweden/Veesp was intentionally not touched.
- Deployment details:
  - node path: `/opt/grani-hy2-test`;
  - Docker container: `grani-hy2-test` using image `tobyxdd/hysteria:latest`;
  - network mode: host;
  - listen: `:443` (UDP 443);
  - TLS: self-signed cert with `CN/SAN=www.bing.com`, `sniGuard: disable`;
  - auth: password from `/opt/grani-hy2-test/password.txt`;
  - obfs: `salamander` with password from `/opt/grani-hy2-test/obfs_password.txt`;
  - masquerade proxy target: `https://www.bing.com/`.
- Verification:
  - `docker ps` shows `grani-hy2-test Up`;
  - container log shows `server up and running {"listen": ":443"}`;
  - `ss -lunp` shows `hysteria` listening on `*:443` UDP.
- Local deliverable created: `outputs/grani-de-hy2-test.txt` with Hysteria2 URI and manual client config.
- Important limitation:
  - This is not integrated into the GRANI app yet. It must be tested via a third-party Android client that supports Hysteria2, e.g. Hiddify/NekoBox-like clients.
  - If LTE works with this PoC, then Hysteria2 becomes a candidate for GRANI protocol integration; if LTE is still dead, the provider/ASN/carrier-path hypothesis remains strong.

## 2026-06-11 - Hysteria2 Germany test: Wi-Fi and LTE reach server

- User reported that Hysteria2 test profile connects but client shows timeout; then clarified the first test was on Wi-Fi.
- Server logs show the Hysteria2 server actually accepts client sessions:
  - Wi-Fi endpoint `94.180.243.40` connected several times;
  - LTE/MegaFon endpoint `178.176.82.237` also connected twice (`08:46:37` and `08:46:52` UTC).
- This is an important distinction from the AWG failures: HY2 UDP/443 reaches the Germany/Hetzner node from LTE, at least enough to establish a Hysteria client session.
- Initial server logs showed downstream TCP timeouts and attempts to route traffic to private/client-side DNS address `172.19.0.2:853`, plus IPv6 destination timeouts. Host and container outbound connectivity to Bing/GitHub work, so the issue was not general server Internet loss.
- Adjusted HY2 test server config only:
  - added resolver `udp 1.1.1.1:53`;
  - forced direct outbound IPv4 only with `mode: 4` and `bindIPv4: 167.233.66.144`;
  - restarted `grani-hy2-test`, now up and running.
- URI did not change. User should reconnect the same profile and test browser/speedtest on Wi-Fi and LTE.
- Interpretation so far:
  - HY2 is promising as a fallback protocol because LTE can reach the Germany test server, unlike AWG behavior on this path.
  - Remaining timeout may be client TUN/DNS/routing behavior in the third-party app, not carrier blocking of UDP/443 to the server.

## 2026-06-11 - Hysteria2 production-like test suite on Germany

- User asked to improve the Hysteria2 test after Android clients showed incoming packets but no usable Internet.
- Checked official Hysteria2 documentation:
  - HY2 mimics HTTP/3/QUIC by default;
  - obfuscation modes are `salamander` and experimental `gecko`;
  - `gecko` builds on salamander and fragments/pads QUIC handshake packets;
  - port hopping is supported by a multi-port server address;
  - client URI alone does not carry all Android TUN/DNS/routing settings, so third-party Android clients can still fail even when the server works.
- No Cloudflare/API credentials for quick DNS+ACME automation were found on the server, so a domain-backed ACME profile was not created yet.
- Created a stronger standalone HY2 test suite on Germany/Hetzner `167.233.66.144`; Sweden/Veesp was not touched.
- Node path: `/opt/grani-hy2-suite`.
- Shared self-signed test cert:
  - SNI/CN/SAN: `www.bing.com`;
  - SHA256 fingerprint: `25:22:84:3B:6D:E6:9E:1C:09:0C:88:17:5F:65:F8:3D:A0:38:D6:90:81:A0:ED:67:6F:68:45:D6:1F:77:47:26`;
  - Android clients still need `insecure=1`; fingerprint is included as an extra pin.
- Containers created:
  - `grani-hy2-salamander443`: UDP `443`, obfs `salamander`;
  - `grani-hy2-gecko8443`: UDP `8443`, obfs `gecko`;
  - `grani-hy2-hop`: UDP `30000-30020`, obfs `salamander`, port hopping, container has `NET_ADMIN` for firewall redirects.
- Server-side hardening applied to all three:
  - resolver `1.1.1.1:53` UDP;
  - outbound IPv4 only, `mode: 4`, `bindIPv4: 167.233.66.144`;
  - `ignoreClientBandwidth: true`;
  - congestion `bbr` / `conservative`;
  - QUIC `maxIdleTimeout: 60s`;
  - QUIC `disablePathMTUDiscovery: true`;
  - masquerade proxy `https://www.bing.com/`.
- Verification:
  - all three containers show `server up and running`;
  - Linux client tests through the same HY2 profiles succeeded:
    - `salamander:443` -> connected, `https://www.bing.com` returned `HTTP/2 200`;
    - `gecko:8443` -> connected, `HTTP/2 200`;
    - `salamander port hopping 30000-30020` -> connected, `HTTP/2 200`.
- Local output file created: `outputs/grani-de-hy2-production-like-tests.txt` with all three URIs and notes.
- Important limitation:
  - This is still not GRANI app integration.
  - Some Android clients may not support `gecko` or multi-port URI import. If Linux works but Android fails, the next suspect is Android client TUN/DNS/routing, not the HY2 server itself.

## 2026-06-11 - Amnezia Premium works on MegaFon LTE

- User tested Amnezia Premium on MegaFon LTE and reported that it works well.
- Speedtest screenshot shows:
  - connection type: LTE / MegaFon;
  - exit/network shown by Speedtest: `AdKyNet SAS`, Paris;
  - external IP: `163.5.173.22`;
  - internal VPN IP: `10.0.42.2`;
  - ping around `111 ms`, download latency around `532 ms`, upload latency around `112 ms`, packet loss `0.0%`.
- User also provided a `vpn://` Amnezia Premium link. It decodes as zlib-compressed JSON with only Premium API metadata, not the actual node config:
  - `name`: `Amnezia Premium`;
  - `config_version`: `2`;
  - `api_config.service_type`: `amnezia-premium`;
  - `api_config.service_protocol`: `awg`;
  - `api_config.user_country_code`: `ru`;
  - `auth_data.api_key`: present (sensitive, not repeated in notes).
- Interpretation:
  - This proves MegaFon LTE can carry VPN traffic well when the provider/IP pool/route/signature are suitable.
  - The working Premium link does not directly reveal AWG/VLESS server parameters; the app likely fetches them dynamically via Amnezia Premium API.
  - The most valuable clues are the working exit IP/ASN/provider and route, not the `vpn://` token itself.
  - GRANI should compare future candidate providers against the working Premium exit characteristics, in addition to Sweden/Veesp.

## 2026-06-11 - Hysteria2 Android tests still not usable

- User tested the improved Hysteria2 profiles in v2RayTun/Hiddify-like Android client.
- Result remains bad:
  - `GRANI-DE-HY2-test`: connected state, sent `28147 bytes / 78 packets`, received only `1060 bytes / 25 packets`, speedtest failed.
  - `GRANI-DE-HY2-salamander-443`: connected for about `01:09`, sent `159690 bytes / 425 packets`, received only `3760 bytes / 91 packets`, speedtest failed.
- Interpretation:
  - Server-side HY2 works with Linux/SOCKS client, but Android full-tunnel usability is not achieved.
  - The HY2 PoC proves UDP/443 can reach Germany from the phone and HY2 handshake can happen, but this is not enough for production Internet on Android.
  - Treat current HY2 work as an experimental diagnostic, not a working fallback protocol.
  - Do not invest more in small HY2 knob tweaks on Hetzner unless switching to a better Android client/sing-box config or a better provider/IP is part of the test.

## 2026-06-11 - Conceptual protocol map requested by user

- User asked for a foundational explanation of WireGuard/AmneziaWG, VLESS/Xray, and Hysteria2: what is a base protocol, what is transport/security/obfuscation, what can be combined, and what modern options exist.
- Sources checked: official Project X/Xray VLESS and transport docs, official Hysteria2 full server config docs, official AmneziaWG docs, Xray-core v25.9.5 release notes.
- Key conceptual points:
  - WireGuard/AmneziaWG is an L3 VPN-style UDP tunnel. AmneziaWG modifies the WireGuard packet appearance with J/S/H/I/junk/signature fields but is still a WireGuard-family tunnel.
  - VLESS is an application proxy protocol used by Xray/sing-box; it normally needs transport security such as TLS/REALITY or newer VLESS Encryption. It can be combined with transports like raw TCP, XHTTP, gRPC, WebSocket, HTTPUpgrade, etc.
  - Hysteria2 is QUIC/UDP-based proxy transport with TLS, optional salamander/gecko obfuscation, congestion control, bandwidth settings, and port hopping. It is not WireGuard and not VLESS, though Xray has a Hysteria transport category.
  - REALITY is a transport-security/camouflage layer for Xray that can combine with RAW, XHTTP, and gRPC, not with every transport.
  - XTLS Vision is a VLESS flow mode/optimization/obfuscation layer, commonly relevant for VLESS over TCP+TLS/REALITY.
  - Xray v25.9.5 introduced modern VLESS Encryption with ML-KEM/X25519-based PFS/AEAD options and a `vlessenc` helper; client compatibility must be checked before product use.
  - Obfuscation layers cannot be arbitrarily stacked across protocol families. Product-level multi-protocol fallback is safer than chaining everything into one tunnel.
- Product implication for GRANI:
  - Treat GRANI as a multi-protocol product: AWG lane, VLESS/Xray/sing-box lane, and possibly HY2 lane.
  - For Russia/LTE, do not rely on one protocol or one provider ASN. Need a matrix: same provider+different protocols and same protocol+different providers.
  - Strong candidate next lane: modern VLESS + REALITY + Vision and/or VLESS + XHTTP + REALITY/TLS, tested on both bad Hetzner/Vultr and good Veesp/NovoServe/Anarchy-like providers.

## 2026-06-11 - Three-protocol roadmap after HY2 domain clarification

- User asked what can still be done in each of the three protocol directions: AWG, VLESS, Hysteria2.
- Current conclusion:
  - Hysteria2 has not been fully tested in its recommended production-like mode because no real domain/ACME certificate/masquerade website was created; only IP + self-signed TLS + `insecure=1` + salamander/gecko/port-hopping was tested.
  - VLESS has not been retested with modern stacks such as `VLESS + REALITY + Vision`, `VLESS + XHTTP + REALITY/TLS`, or newer VLESS Encryption-compatible clients.
  - AWG was improved to AWG2-like profile on Osaka and works on Wi-Fi but fails on LTE for some providers; remaining work is provider/ASN testing plus AWG signature rotation, not more blind port/MTU churn.
- Roadmap:
  - AWG lane: preserve Sweden as control, rotate AWG signatures (`Jc/I1/S/H`) on non-working nodes, test same AWG config on Veesp/NovoServe/Anarchy-like providers, improve reconnect/network-switch behavior in GRANI Android when APK build is requested.
  - VLESS lane: create fresh modern Xray/sing-box tests, not revive old broken branches; start with `VLESS + REALITY + Vision`, then `VLESS + XHTTP + REALITY/TLS`, then evaluate VLESS Encryption only if Android client compatibility is confirmed.
  - HY2 lane: create real domain-backed Hysteria2 test with direct DNS A-record, ACME cert, masquerade website, no `insecure=1`, then compare normal HTTPS camouflage vs salamander/gecko/port hopping.
- Product strategy:
  - GRANI should become multi-protocol with smart fallback: AWG as fast tunnel where provider supports it, VLESS as likely strongest censorship fallback, HY2 as UDP/unstable-network fallback where client/server stack is proven.

## 2026-06-11 - VLESS REALITY Vision test on Germany

- Started the VLESS lane as requested after the conceptual protocol discussion.
- Test node: Germany/Hetzner `167.233.66.144`. Sweden/Veesp was not touched.
- Existing `443/tcp` is already occupied by the older `amnezia-xray` container, so the test uses `8443/tcp`.
- Created `/opt/grani-vless-reality-vision` on the Germany node.
- Docker container: `grani-vless-reality-vision`, image `ghcr.io/xtls/xray-core:latest`.
- Xray version observed: `26.3.27`.
- Server config:
  - inbound: VLESS on TCP `8443`;
  - security: REALITY;
  - flow: `xtls-rprx-vision`;
  - destination camouflage: `www.microsoft.com:443`;
  - SNI/serverName: `www.microsoft.com`;
  - client UUID: `96121987-66b2-48b5-88e5-c84267476c5f`;
  - public key: `JOsa6PzDb5EyTGX5XzuZiW1dbeMtO--NkW9U3IbD_BI`;
  - short ID: `1387ffa617df8443`;
  - outbound uses direct IPv4 preference.
- Verification:
  - container is up and listening on `*:8443`;
  - Linux Xray client with the same VLESS REALITY Vision config connected successfully;
  - `curl` through local SOCKS returned `HTTP/2 200` from `https://www.bing.com`;
  - `curl https://ipinfo.io/ip` through the proxy returned `167.233.66.144`.
- Local output created: `outputs/grani-de-vless-reality-vision-test.txt` with URI and manual fields.
- Notes:
  - Xray emits a warning that REALITY on non-443 ports may be less ideal. This is expected for this test because 443/tcp is occupied. A production test should move REALITY to 443 on a clean node or a node where old xray is removed/replaced.
  - Next user test: import the URI into an Android client supporting VLESS REALITY + Vision, then check Wi-Fi and LTE.

## 2026-06-11 - Android test result: VLESS REALITY Vision on Germany also not usable

- User tested the new Germany VLESS REALITY Vision profile from `outputs/grani-de-vless-reality-vision-test.txt`.
- Result: same pattern as Hysteria2 Android tests:
  - packets are present;
  - speedtest fails;
  - Internet is not usable.
- Server-side Linux validation had succeeded earlier (`HTTP/2 200` through Xray SOCKS, external IP `167.233.66.144`), so the server config itself is functional for a normal proxy client.
- Interpretation:
  - On Germany/Hetzner, Android full-tunnel tests fail across three protocol families: AWG, Hysteria2, and VLESS REALITY Vision.
  - This makes small protocol tweaks on the same Hetzner node low-value.
  - Stronger current hypothesis: Germany/Hetzner + Android full-tunnel/mobile path is a bad test platform for GRANI target conditions; next meaningful test should move the same protocol set to a better ASN/IP pool (Veesp/NovoServe/Anarchy-like) or use a clean node with 443/tcp available for production-like REALITY.
EOF

## 2026-06-11 - VLESS REALITY Vision test on Sweden/Veesp

- User asked to try VLESS on Sweden because Sweden unexpectedly works well with AWG on LTE.
- Sweden/Veesp node `13.140.9.211` was used. Existing working AWG container was not modified.
- Port situation before change:
  - working `amnezia-awg2` container uses UDP `39550`;
  - raw `wg0`/UDP `51820` exists;
  - TCP `443` was free.
- Created `/opt/grani-vless-reality-vision` on Sweden.
- Docker container: `grani-vless-reality-vision`, image `ghcr.io/xtls/xray-core:latest`, run as root so it can bind TCP `443`.
- Xray version observed: `26.3.27`.
- Server config:
  - inbound: VLESS on TCP `443`;
  - security: REALITY;
  - flow: `xtls-rprx-vision`;
  - destination camouflage: `www.microsoft.com:443`;
  - SNI/serverName: `www.microsoft.com`;
  - UUID: `6417dcbf-b0d2-4b6f-8021-86025abfe1a8`;
  - public key: `6JWIB37ukPngDlrBK7MeAYgjaAojgeLY-DgeWdDcnGw`;
  - short ID: `ad743ce79285fb48`;
  - outbound uses direct IPv4 preference.
- Verification:
  - container is up and listening on `*:443`;
  - Linux Xray client with the same VLESS REALITY Vision config connected successfully;
  - `curl` through local SOCKS returned `HTTP/2 200` from `https://www.bing.com`;
  - `curl https://ipinfo.io/ip` through the proxy returned `13.140.9.211`.
- Local output created: `outputs/grani-se-vless-reality-vision-test.txt` with URI and manual fields.
- Next user test: import URI into Android client supporting VLESS REALITY + Vision and compare Wi-Fi/LTE behavior against Germany VLESS and Sweden AWG.

## 2026-06-11 - Sweden VLESS REALITY Vision Android failure diagnostics

- User tested Sweden/Veesp VLESS REALITY Vision profile and reported that it does not work.
- Node check:
  - `grani-vless-reality-vision` container is up;
  - Xray listens on `*:443`;
  - working Sweden AWG container/UDP `39550` was not touched.
- Xray logs during the Android test show many inbound attempts from Russian mobile/user IPs, especially `178.176.82.237` and `94.180.243.40`, failing with:
  - `REALITY: processed invalid connection ... failed to read client hello`;
  - `handshake did not complete successfully`.
- There was also at least one accepted VLESS request:
  - `from 94.180.243.40 ... accepted tcp:www.google.com:443 [vless-reality-vision-443 >> direct4]`.
- Interpretation:
  - This is not a simple reachability problem: TCP/443 reaches the Sweden node.
  - This is also different from the earlier AWG/Osaka LTE case: the server is seeing malformed or incomplete REALITY handshakes from the Android-side path/client.
  - Most likely next variables are Android client import/compatibility with `VLESS + REALITY + xtls-rprx-vision`, or client health-check/probe traffic hitting the REALITY port.
- Next non-invasive test:
  - Add a second Sweden VLESS REALITY profile without `xtls-rprx-vision` flow on a separate port, leaving the current Vision/443 profile and AWG untouched.

## 2026-06-11 - Sweden VLESS REALITY no-flow control profile

- Added a second VLESS REALITY profile on Sweden/Veesp without `xtls-rprx-vision`.
- Existing services were left untouched:
  - Sweden AWG still uses UDP `39550`;
  - Sweden VLESS REALITY Vision remains on TCP `443`.
- New container:
  - `grani-vless-reality-noflow`;
  - image `ghcr.io/xtls/xray-core:latest`;
  - listens on TCP `8443`.
- New profile fields:
  - IP: `13.140.9.211`;
  - port: `8443`;
  - UUID: `6417dcbf-b0d2-4b6f-8021-86025abfe1a8`;
  - security: `reality`;
  - flow: empty / none;
  - public key: `6JWIB37ukPngDlrBK7MeAYgjaAojgeLY-DgeWdDcnGw`;
  - short ID: `ad743ce79285fb48`;
  - SNI/serverName: `www.microsoft.com`;
  - fingerprint: `chrome`;
  - spiderX: `/`.
- Verification:
  - `ss` shows Xray listening on `*:8443`;
  - Linux Xray client from the DO control host connected successfully;
  - `curl` through local SOCKS returned `HTTP/2 200` from Bing;
  - external IP through proxy returned `13.140.9.211`.
- Local output created: `outputs/grani-se-vless-reality-noflow-test.txt`.
- Purpose:
  - Check whether Android client failure is specifically related to `xtls-rprx-vision` compatibility/import.
  - If no-flow works on Android where Vision fails, the next GRANI VLESS implementation should prefer REALITY no-flow first, then add Vision only after client compatibility is proven.

## 2026-06-11 - Sweden VLESS REALITY no-flow Android/Wi-Fi result

- User tested the Sweden VLESS REALITY no-flow profile on Wi-Fi and reported that it also does not work.
- Node check after the test:
  - `grani-vless-reality-noflow` is up;
  - `grani-vless-reality-vision` is up;
  - Xray listens on `*:443` and `*:8443`;
  - Sweden AWG is still untouched and running on UDP `39550`.
- Logs for no-flow/`8443`:
  - Linux control test from DO still shows valid accepted VLESS requests and successful outbound traffic.
  - During the user Android/Wi-Fi test from `94.180.243.40`, no normal VLESS requests were accepted.
  - Xray logged repeated REALITY failures:
    - `handshake did not complete successfully`;
    - `failed to read client hello`.
- Logs for Vision/`443`:
  - There were earlier successful accepted requests through `vless-reality-vision-443`, including `www.google.com`, Telegram/Facebook/Instagram/WhatsApp-related destinations and UDP DNS over mux.
  - There were also repeated invalid REALITY handshakes from `94.180.243.40`.
- Interpretation:
  - Sweden/Veesp is reachable on TCP and Xray is alive.
  - The no-flow profile does not solve the Android-side REALITY handshake problem.
  - Current VLESS REALITY tests are inconclusive as a GRANI direction until the exact Android client/import format is controlled; the server-side profile works from Linux, but user Android traffic mostly arrives as malformed/incomplete REALITY.
  - This result weakens the idea that simply moving VLESS to the working Sweden provider is enough.

## 2026-06-11 - New direction: postpone AWG changes; test VLESS transports and domain HY2

- User decided to postpone AWG/LTE work for now:
  - no more AWG changes until there is a better idea than buying a Veesp-like provider;
  - Sweden AWG remains the working control node and must not be disturbed.
- New focus:
  - continue VLESS variants other than REALITY Vision/no-flow;
  - complete a proper Hysteria2 domain/TLS/masquerade test.
- Checked official docs:
  - Xray VLESS separates base VLESS from security/transport/flow; no-flow and `xtls-rprx-vision` are different flow choices.
  - Xray XHTTP is the modern replacement direction for older HTTP-like transports; WebSocket works as a compatibility control but Xray warns it is deprecated.
  - Hysteria2 official docs support ACME, real domain TLS, masquerade, Salamander/Gecko obfuscation and port hopping. Prior IP+self-signed tests were therefore not production-like.

## 2026-06-11 - Sweden/Veesp Hysteria2 with real domain and ACME

- User added Cloudflare DNS record:
  - `hy2-se.granilink.com`;
  - type `A`;
  - content `13.140.9.211`;
  - proxy status `DNS only` (correct; Cloudflare proxy must not be used for HY2/VPN endpoints).
- Created a proper domain HY2 test on Sweden/Veesp:
  - container `grani-hy2-domain`;
  - image `tobyxdd/hysteria:latest`;
  - UDP `443`;
  - domain `hy2-se.granilink.com`;
  - Let's Encrypt ACME HTTP-01 on TCP `80`;
  - real certificate obtained successfully;
  - `insecure=false`;
  - file masquerade enabled;
  - no obfuscation yet, to isolate domain/TLS baseline;
  - conservative BBR profile and path MTU discovery disabled.
- Existing services left untouched:
  - Sweden AWG remains on UDP `39550`;
  - VLESS REALITY Vision remains on TCP `443`;
  - VLESS no-flow remains on TCP `8443`.
- Linux control test from DO:
  - Hysteria client connected to `13.140.9.211:443`;
  - `curl` through local SOCKS returned `HTTP/2 200`;
  - external IP through proxy returned `13.140.9.211`.
- Local output:
  - `outputs/grani-se-hy2-granilink-domain-test.txt`.
- Android test priority:
  - first test this HY2 domain profile on Wi-Fi and LTE;
  - if it works on Wi-Fi but fails on LTE, add obfs variants on the same real-domain baseline: Salamander, then Gecko.

## 2026-06-11 - Sweden/Veesp VLESS WebSocket plain control

- Added a VLESS WebSocket control profile on Sweden/Veesp to test VLESS without REALITY.
- Container:
  - `grani-vless-ws`;
  - image `ghcr.io/xtls/xray-core:latest`;
  - TCP `8080`;
  - UUID `b7f4087a-5eb5-4d5e-8d05-1d5ff93447a0`;
  - network `ws`;
  - security `none`;
  - path `/grani-ws`.
- Purpose:
  - diagnostic compatibility test only, not a production-safe final profile;
  - checks whether Android client can handle VLESS+WS at all, without REALITY handshake.
- Linux control test:
  - `curl` through local Xray SOCKS returned `HTTP/2 200`;
  - external IP through proxy returned `13.140.9.211`.
- Xray warning:
  - WebSocket transport is deprecated/not recommended and Xray suggests migrating to XHTTP.
- Local output:
  - `outputs/grani-se-vless-ws-plain-test.txt`.

## 2026-06-11 - Sweden/Veesp VLESS XHTTP plain control

- Added a VLESS XHTTP control profile on Sweden/Veesp.
- Container:
  - `grani-vless-xhttp`;
  - image `ghcr.io/xtls/xray-core:latest`;
  - TCP `8081`;
  - UUID `3cc4793f-1dcc-4d50-b92d-bc0e8a8f3160`;
  - network `xhttp`;
  - security `none`;
  - path `/grani-xhttp`;
  - mode `packet-up`.
- Purpose:
  - modern VLESS transport compatibility test without REALITY/TLS;
  - `packet-up` chosen as the conservative/compatible XHTTP mode based on Xray docs/discussion.
- Linux control test:
  - Xray client connected in XHTTP `packet-up` mode over HTTP/1.1;
  - `curl` through local Xray SOCKS returned `HTTP/2 200`;
  - external IP through proxy returned `13.140.9.211`.
- Local output:
  - `outputs/grani-se-vless-xhttp-plain-test.txt`.
- Android test priority:
  - test XHTTP after HY2;
  - if XHTTP plain works, next production-like step is domain/TLS or Cloudflare-compatible XHTTP using `granilink.com` DNS records.

## 2026-06-11 - Android result: HY2 domain on Sweden works

- User tested the new Hysteria2 domain profile `hy2-se.granilink.com:443`.
- Screenshots:
  - Wi-Fi result: Speedtest download reached about `73.27 Mbps`; endpoint/provider shown as Veesp/Telia Sweden/PVDataNet Stockholm.
  - LTE/MegaFon result: Speedtest started and showed about `1.03 Mbps` download with high latency/jitter; this is a major improvement over previous LTE cases with no inbound packets or failed start.
- Node logs confirm the user traffic was HY2, not VLESS:
  - container `grani-hy2-domain` received user connections from `94.180.243.40` and `178.176.82.244`;
  - VLESS WS/XHTTP logs only show earlier Linux control checks from the DO host, not the Android user test.
- HY2 log details:
  - `client connected` from `94.180.243.40:49199`;
  - many Speedtest/Ookla and app destinations appeared, including `www.ookla.com`, `speedtest-univ-results-api.speedtest.net`, `user-api.speedtest.net`, several Speedtest server IPs on `:8080`, Google/Meta/OpenAI/RevenueCat/VK/RuStore endpoints;
  - later the connection ended with remote stream cancels and `timeout: no recent network activity`.
  - LTE connection from `178.176.82.244:27296` also connected and carried traffic, then hit multiple `timeout: no recent network activity` errors.
- Interpretation:
  - The real-domain HY2 baseline succeeded where previous IP+self-signed HY2 was not useful.
  - On Wi-Fi, HY2 domain/ACME is a clear working result.
  - On LTE, HY2 is no longer dead: it connects and passes traffic/Speedtest, but performance is poor and stability needs tuning.
  - The next HY2 experiments should tune this working baseline rather than start from scratch:
    - try Salamander obfuscation with the same domain/TLS baseline;
    - try Gecko only if the Android client supports it;
    - evaluate port hopping or alternate UDP port only after obfs baseline;
    - consider client/server BBR/aggressive vs conservative and QUIC keepalive/PMTU settings.

## 2026-06-11 - Sweden HY2 domain switched to Salamander obfs test

- User asked to proceed after HY2 domain success.
- Replaced the active `grani-hy2-domain` container on Sweden/Veesp UDP `443` with a Salamander-obfuscated version.
- Important:
  - Sweden AWG was not touched.
  - VLESS test containers were not touched.
  - The previous non-obfs HY2 domain profile cannot work while this Salamander container owns UDP `443`; restore `server-granilink.yaml` if non-obfs needs to be tested again.
- Server:
  - domain: `hy2-se.granilink.com`;
  - DNS remains Cloudflare `DNS only`;
  - TLS: existing Let's Encrypt cert for `hy2-se.granilink.com`;
  - auth/password: `GRANI-SE-HY2-domain-20260611`;
  - obfs: `salamander`;
  - obfs password: `GRANI-SE-HY2-salamander-20260611`;
  - conservative BBR profile, keepalive, and disabled PMTU discovery kept from the working baseline.
- Linux control test from DO:
  - Hysteria2 client with matching Salamander obfs connected to `13.140.9.211:443`;
  - `curl` through local SOCKS returned `HTTP/2 200`;
  - external IP through proxy returned `13.140.9.211`.
- Local output:
  - `outputs/grani-se-hy2-granilink-salamander-test.txt`.
- Next Android test:
  - import/test the Salamander URI;
  - compare Wi-Fi speed against previous non-obfs result (~73 Mbps);
  - compare LTE stability/speed against previous non-obfs result (~1 Mbps, unstable but not dead).

## 2026-06-11 - Android result: Sweden AWG vs HY2 Salamander on LTE both poor

- User compared Sweden AWG and Sweden HY2 Salamander on LTE/MegaFon.
- User notes:
  - the Wi-Fi icon in one screenshot should not be trusted; both tests were effectively LTE comparison;
  - Sweden AWG and HY2 Salamander results are almost identical and very poor;
  - likely either strong local/current blocking or this Sweden server/path will not give better Hysteria2 results on LTE.
- Screenshot-level results:
  - Sweden AWG/LTE-ish Speedtest: about `0.13 Mbps` download, `0.00 Mbps` upload, ping `184 ms`, very high loaded latency/jitter.
  - Sweden HY2 Salamander/LTE: about `0.07 Mbps` download, `0.06 Mbps` upload, ping `251 ms`, extremely high loaded latency/jitter.
- Node logs for HY2 Salamander confirm:
  - client connected successfully from MegaFon-related IPs, including `178.176.82.244` and `94.180.243.40`;
  - Salamander handshake/auth was not the failure point;
  - traffic reached real destinations, including Speedtest/Ookla, Telegram, Google, Yandex, Meta and other app endpoints;
  - failures are mostly remote stream cancellations, resets, and `timeout: no recent network activity`.
- Interpretation:
  - Salamander does not materially improve this LTE path compared with plain domain HY2 or Sweden AWG.
  - The issue is now more likely current MegaFon/local radio/path quality or route/provider behavior to Sweden under load, not a missing HY2 obfuscation field.
  - Further HY2 obfs tweaking on the same Sweden node is lower priority unless testing a different mobile operator/location.
- Recommended next protocol tests:
  - test VLESS XHTTP plain and VLESS WS plain on the same LTE/Wi-Fi to see whether TCP/HTTP-like transports survive this path better than UDP-based AWG/HY2;
  - if XHTTP works, move it to a production-like domain/TLS/Cloudflare-compatible setup.

## 2026-06-11 - Android result: VLESS WebSocket plain is the current LTE leader

- User tested VLESS WebSocket plain profile:
  - `vless://b7f4087a-5eb5-4d5e-8d05-1d5ff93447a0@13.140.9.211:8080?type=ws&security=none&path=%2Fgrani-ws&encryption=none#GRANI-SE-VLESS-WS-plain-8080`
- LTE/MegaFon Speedtest screenshot:
  - download about `6.48 Mbps`;
  - upload about `0.55 Mbps`;
  - ping `89 ms`;
  - loaded latency still high, but materially better than Sweden AWG and HY2 Salamander in the same conditions.
- Node logs confirm the test used `grani-vless-ws`:
  - many accepted VLESS WS requests from MegaFon IP `178.176.82.244`;
  - real destinations included Yandex, VK analytics, app endpoints, etc.;
  - normal/expected WebSocket closes also appear, but this profile clearly passed meaningful traffic.
- XHTTP was not successfully tested yet:
  - `grani-vless-xhttp` logs only show failed path validation requests such as `/` and `/login`;
  - no accepted Android VLESS XHTTP requests to `/grani-xhttp` were observed.
- Interpretation:
  - TCP/HTTP-like VLESS WS currently beats UDP-based AWG/HY2 on this bad MegaFon LTE path.
  - Although Xray warns WebSocket is deprecated and XHTTP is the modern direction, WS is currently the practical working lead.
- Next production-like step:
  - create a domain/TLS VLESS WS profile, preferably on `ws-se.granilink.com`;
  - Cloudflare can be tested in two modes:
    - DNS only direct-to-origin first;
    - Proxied later if we want CDN behavior and client supports it.
  - Do not keep `security=none` on public production; current `8080` profile is diagnostic only.

## 2026-06-11 - Android result: VLESS XHTTP plain is worse than WS

- User tested VLESS XHTTP plain:
  - `vless://3cc4793f-1dcc-4d50-b92d-bc0e8a8f3160@13.140.9.211:8081?type=xhttp&security=none&path=%2Fgrani-xhttp&mode=packet-up&encryption=none#GRANI-SE-VLESS-XHTTP-plain-8081`
- User result:
  - bad performance;
  - Speedtest fails.
- Node logs confirm this was now a real XHTTP test, not just wrong path:
  - accepted requests from MegaFon IP `178.176.82.244`;
  - Speedtest destinations appeared, including `speedtest-sth.84grams.net`, `speedtest-sth.netatonce.net`, `speedtestse.pvdatanet.com`, `se-speedt02.hy.nis.telia.net`, `speedtest.telenor.se`, etc.;
  - app traffic also passed via XHTTP.
- Server-side issues observed:
  - several Speedtest `:80` targets refused connections from the server side;
  - XHTTP had `packet queue closed` and EOFs under load.
- Interpretation:
  - XHTTP plain was imported/used correctly, but performs worse than VLESS WS on this Android/MegaFon LTE path.
  - Despite Xray's deprecation warning for WS, the practical leader remains VLESS WebSocket plain on TCP `8080`.
- Next step remains:
  - production-like VLESS WS with domain/TLS first;
  - only revisit XHTTP later with domain/TLS/H2/H3/CDN variants if WS cannot be productionized safely.

## 2026-06-11 - Domain exposure risk for VPN protocol tests

- User asked whether using the main `granilink.com` domain/subdomains for protocol tests is safe.
- Conclusion:
  - using `hy2-se.granilink.com` / future `ws-se.granilink.com` makes the GRANI brand/domain visible in DNS, SNI, certificates, Certificate Transparency logs, and active-probing surfaces;
  - this does not guarantee an immediate block, but it creates unnecessary blast radius for the public app/API domain;
  - for production VPN transports, prefer a separate disposable/non-brand domain or at least a separate zone from `granilink.com`.
- Safer rollout recommendation:
  - keep `granilink.com` for app/API/admin only;
  - use a separate protocol domain for VPN transports;
  - use per-node/per-protocol subdomains under that separate domain;
  - test DNS-only direct first, then Cloudflare proxied only for TCP/HTTP-like transports such as VLESS WS where applicable;
  - avoid putting UDP protocols such as AWG/HY2 behind Cloudflare proxy.

## 2026-06-11 - Sweden VLESS WS TLS on ws-se.granilink.com

- User created Cloudflare DNS record:
  - `ws-se.granilink.com` A `13.140.9.211`;
  - Proxy status: DNS only.
- Sweden node setup:
  - stopped failed test container `grani-vless-reality-vision` that occupied TCP `443`;
  - did not touch working `amnezia-awg2` on UDP `39550`;
  - did not touch HY2 `grani-hy2-domain` on UDP `443`;
  - kept diagnostic plain WS on TCP `8080` and XHTTP on TCP `8081`.
- First attempt:
  - started Caddy TLS reverse proxy on TCP `443` with backend Xray WS on internal TCP `10080`;
  - Let's Encrypt certificate for `ws-se.granilink.com` was issued successfully;
  - Linux client reached the local SOCKS inbound, but HTTPS targets reset (`api.ipify.org`, Google, Bing);
  - conclusion: Caddy reverse-proxy layer is not a good data-path for this VLESS WS test.
- Working setup:
  - stopped Caddy data-path containers;
  - started direct Xray TLS+WebSocket container `grani-vless-ws-tls-direct` on TCP `443`;
  - Xray uses the already issued Caddy certificate from `/opt/grani-node-tests/caddy-data/.../ws-se.granilink.com`;
  - Xray runs as root inside the container only so it can read the Caddy-managed key files without chmod weakening.
- Linux control result through VLESS WS TLS:
  - SOCKS test returned external IP `13.140.9.211`;
  - Google `generate_204` returned `204`;
  - Bing returned `HTTP/2 200`.
- Android test URI:
  - `vless://b7f4087a-5eb5-4d5e-8d05-1d5ff93447a0@ws-se.granilink.com:443?type=ws&security=tls&sni=ws-se.granilink.com&host=ws-se.granilink.com&path=%2Fgrani-ws&alpn=http%2F1.1&encryption=none#GRANI-SE-VLESS-WS-TLS-443`
- Important caveat:
  - certificate renewal is not productionized yet because Caddy is not in the active data path now;
  - acceptable for immediate Android/LTE test;
  - before production integration, add a clean cert renewal mechanism or run a permanent TLS terminator that does not break WS traffic.

## 2026-06-11 - Practical multi-protocol matrix rollout on current nodes

- User decided to move from isolated tests toward a practical multi-protocol node matrix.
- Target display/protocol order:
  - `VLESS WS`;
  - `Hysteria 2`;
  - `WireGuard obf`.
- DNS state:
  - `ws-se.granilink.com -> 13.140.9.211`, DNS only;
  - `ws-de.granilink.com -> 167.233.66.144`, DNS only;
  - `ws-fi.granilink.com -> 204.168.160.160`, DNS only;
  - `ws-jp.granilink.com -> 66.245.219.118`, DNS only;
  - `ws-sg.granilink.com -> 149.28.139.231`, DNS only.
- SSH/key findings:
  - SE/DE/FI/JP accessible via `/root/.ssh/grani_nodes_ed25519`;
  - SG accessible via `/root/.ssh/grani_amnezia_ed25519`.
- VLESS WS rollout:
  - best practical VLESS profile remains plain WebSocket on TCP `8080`, path `/grani-ws`, UUID `b7f4087a-5eb5-4d5e-8d05-1d5ff93447a0`;
  - installed native systemd service `grani-vless-ws` on DE/FI/JP/SG using Xray `26.3.27`;
  - Sweden already had Docker container `grani-vless-ws` on TCP `8080` and was not changed;
  - Xray outbound updated with `domainStrategy: UseIPv4`;
  - SG initially failed Linux control because UFW did not allow TCP `8080`; added `ufw allow 8080/tcp`, then control passed.
- VLESS Linux control from `grani-do`:
  - SE -> external IP `13.140.9.211`, Google `204`;
  - DE -> external IP `167.233.66.144`, Google `204`;
  - FI -> external IP `204.168.160.160`, Google `204`;
  - JP/Osaka -> external IP `66.245.219.118`, Google `204`;
  - SG -> external IP `149.28.139.231`, Google `204`.
- Hysteria2 rollout:
  - selected the plain domain/TLS baseline as "best HY2" because it previously beat Salamander on Sweden Wi-Fi/LTE;
  - Sweden `grani-hy2-domain` switched back from Salamander to plain `server-granilink.yaml`;
  - DE/FI/JP/SG installed native systemd service `grani-hy2-domain` using Hysteria `2.9.2`;
  - DE old failed/test `grani-hy2-salamander443` was stopped to free UDP `443`; AWG was not touched;
  - ACME HTTP-01 certificates issued successfully for `ws-de`, `ws-fi`, `ws-jp`, `ws-sg`;
  - UFW opened where active: TCP `80` for ACME and UDP `443` for HY2.
- HY2 Linux control from `grani-do`:
  - SE `hy2-se.granilink.com:443` -> external IP `13.140.9.211`, Google `204`;
  - DE `ws-de.granilink.com:443` -> external IP `167.233.66.144`, Google `204`;
  - FI `ws-fi.granilink.com:443` -> external IP `204.168.160.160`, Google `204`;
  - JP/Osaka `ws-jp.granilink.com:443` -> external IP `66.245.219.118`, Google `204`;
  - SG `ws-sg.granilink.com:443` -> external IP `149.28.139.231`, Google `204`.
- WireGuard obf/AWG state:
  - SE working AWG control remains untouched (`amnezia-awg2` Docker on UDP `39550`, raw wg0 UDP `51820`);
  - Osaka full AWG2 profile remains untouched and still active on UDP `51820`;
  - DE AWG runtime active on UDP `39060`;
  - SG AWG runtime active on UDP `4500`;
  - FI `wg0` runtime exists and `awg show wg0` works on UDP `51820`, but `systemctl is-active awg-quick@wg0` reports `inactive`; treat this as a separate cleanup/persistence task, not fixed in this pass.
- User-facing manual import file created locally:
  - `outputs/grani-protocol-matrix-20260611.txt`;
  - includes VLESS WS and HY2 URIs for SE/DE/FI/JP/SG.

## 2026-06-11 - UI protocol labels updated, no APK build

- User requested labels/order:
  - `VLESS WS`;
  - `Hysteria 2`;
  - `WireGuard obf`.
- Flutter changes:
  - `lib/models/vpn_protocol.dart`: display name for internal `graniwg` changed from `GraniWG` to `WireGuard obf`;
  - `lib/simple_vpn/simple_vpn_api.dart`: `SimpleVpnProtocol.label` now maps `vless_ws -> VLESS WS`, `hysteria2 -> Hysteria 2`, `graniwg -> WireGuard obf`;
  - `SimpleVpnApi.displayProtocols` provides the display order `VLESS WS`, `Hysteria 2`, `WireGuard obf`;
  - `lib/simple_vpn/simple_vpn_controller.dart`: initial/cached protocol list allows the three display ids, but `selectProtocol()` still only switches to `graniwg` because VLESS/HY2 native runtime integration is not implemented yet;
  - `lib/screens/subscription_activated_screen.dart`: legacy protocol grid changed from old `VLESS/REALITY/VMESS/IKEv2/L2TP/SSTP` to the requested three labels;
  - l10n subtitle changed from "Protected WireGuard"/"Защищенный WireGuard" to "Obfuscated WireGuard"/"Обфусцированный WireGuard".
- Validation:
  - ran `/opt/flutter/bin/dart format` on changed Dart files;
  - ran targeted `/opt/flutter/bin/flutter analyze ... --no-fatal-infos --no-fatal-warnings`;
  - analyze returned exit code 0 with only pre-existing/legacy info-level `prefer_const` hints in `subscription_activated_screen.dart`;
  - APK was not built.

## 2026-06-11 - Hysteria2 moved from temporary ws-* domains to hy2-* domains

- User created dedicated Cloudflare DNS records, all DNS only:
  - `hy2-de.granilink.com -> 167.233.66.144`;
  - `hy2-fi.granilink.com -> 204.168.160.160`;
  - `hy2-jp.granilink.com -> 66.245.219.118`;
  - `hy2-se.granilink.com -> 13.140.9.211`;
  - `hy2-sg.granilink.com -> 149.28.139.231`.
- Action taken:
  - switched DE/FI/JP/SG Hysteria2 `server.yaml` from temporary `ws-*` domains to the proper `hy2-*` domains;
  - kept passwords/ports/settings unchanged;
  - restarted only `grani-hy2-domain` services;
  - backup created on each changed node as `/opt/grani-hy2-domain/server.yaml.bak-hy2-domain-<timestamp>`.
- Certificate status:
  - Let's Encrypt HTTP-01 certificates were issued successfully for `hy2-de`, `hy2-fi`, `hy2-jp`, and `hy2-sg`;
  - `hy2-se` was already using the correct HY2 domain.
- Linux control from `grani-do` after the switch:
  - `hy2-se.granilink.com:443` -> external IP `13.140.9.211`, Google `204`;
  - `hy2-de.granilink.com:443` -> external IP `167.233.66.144`, Google `204`;
  - `hy2-fi.granilink.com:443` -> external IP `204.168.160.160`, Google `204`;
  - `hy2-jp.granilink.com:443` -> external IP `66.245.219.118`, Google `204`;
  - `hy2-sg.granilink.com:443` -> external IP `149.28.139.231`, Google `204`.
- Updated local manual URI file:
  - `outputs/grani-protocol-matrix-20260611.txt` now uses `hy2-*` for Hysteria2 and keeps `ws-*`/IP-based entries for VLESS WS.

## 2026-06-11 - VLESS WS plain Android failures and Sweden-aligned server fix
- User tested VLESS WS plain 8080 configs for DE/FI/JP/SG on Wi-Fi and LTE; all failed in Android client, while the client UI still showed node latency/reachability.
- Checked node logs after Android tests:
  - DE/FI/JP/SG `grani-vless-ws` were receiving traffic from user IPs (`94.180.243.40`, `178.176.82.238`), including DNS/Speedtest/HTTPS destinations.
  - This proves the nodes/ports were reachable; failure is not “port closed”. The failure mode was dirty stream closure/data-plane instability: `websocket close 1006 unexpected EOF`, `failed to read packet length`, `connection reset by peer`, `use of closed network connection`.
- Compared working Sweden VLESS WS plain with new native services:
  - Sweden Docker config uses WS on 8080, `security: none`, sniffing `destOverride: [http, tls]`, outbound `UseIPv4`.
  - New native configs had `destOverride: [http, tls, quic]` and a slightly different skeleton.
- Adjusted DE/FI/JP/SG VLESS WS configs to be closer to Sweden:
  - removed `quic` from sniffing;
  - set stream `security: none`;
  - removed empty client `flow`;
  - kept outbound `domainStrategy: UseIPv4`.
- Tried to also copy Sweden private-IP routing block, but native Xray services lack `geoip.dat`; this caused `failed to load GeoIP: private`. Removed that routing block again. Services are active.
- Linux control from `grani-do` after fix passed for all four VLESS WS plain endpoints:
  - DE `167.233.66.144:8080` -> HTTP 204, external IP `167.233.66.144`.
  - FI `204.168.160.160:8080` -> HTTP 204, external IP `204.168.160.160`.
  - JP `66.245.219.118:8080` -> HTTP 204, external IP `66.245.219.118`.
  - SG `149.28.139.231:8080` -> HTTP 204, external IP `149.28.139.231`.
- Next Android retest should use the same existing VLESS WS plain links. If failures remain, compare Android logs after this `quic` removal; then likely test WebSocket-over-domain/TLS or provider/ASN differences rather than basic reachability.

## 2026-06-11 - DE VLESS WS Android retest with UDP/443 block
- User retested Germany VLESS WS plain after Sweden-aligned config; result unchanged.
- During live Android test, DE Xray logs showed the phone IP `94.180.243.40` reaching the service and opening both UDP/443 and TCP/443 destinations.
- Temporary server-only test on DE blocked `udp/443` inside VLESS routing to force TCP/TLS instead of QUIC-over-WS. User reported no improvement.
- Logs during the UDP/443-block test showed Speedtest/Google/Android TCP destinations opening through `direct4`, but the session still ended with `websocket close 1006 (abnormal closure): unexpected EOF` and closed network connection events.
- Conclusion: DE failure is not explained only by QUIC/UDP/443. Reverted DE VLESS WS config to baseline without the UDP/443 block; service is active.

## 2026-06-11 - SE Hysteria 2 domain works on Wi-Fi and LTE
- User tested `hysteria2://GRANI-SE-HY2-domain-20260611@hy2-se.granilink.com:443/?sni=hy2-se.granilink.com#GRANI-SE-HY2-domain-443`.
- Result: Hysteria 2 domain on Sweden works on Wi-Fi and also on LTE.
- This is now the strongest non-WireGuard baseline: same user/MegaFon LTE where many AWG/VLESS tests failed can pass Hysteria 2 on Sweden domain/UDP 443.
- Next useful comparison: test the same HY2 domain profile shape on DE/FI/JP/SG (`hy2-de`, `hy2-fi`, `hy2-jp`, `hy2-sg`) to separate protocol success from Sweden/Veesp/provider/route success.

## 2026-06-11 - HY2 DE/FI/JP Android retest failed; handshake reaches nodes
- User tested Hysteria 2 domain profiles on Germany, Japan/Osaka and Finland over LTE and Wi-Fi; result: failure, app reports nodes unavailable/not usable.
- Server inspection:
  - DNS is correct: `hy2-de -> 167.233.66.144`, `hy2-fi -> 204.168.160.160`, `hy2-jp -> 66.245.219.118`.
  - `grani-hy2-domain` is active on all three and listens on UDP `:443`.
  - ACME certs were issued successfully for all three domains.
  - Configs match the working Sweden profile in relevant fields: password auth, domain ACME, UDP 443, `disablePathMTUDiscovery: true`, `ignoreClientBandwidth: true`, `bbrProfile: conservative`, direct IPv4 outbound with bindIPv4.
- Logs during user tests show the phone IP `94.180.243.40` connecting successfully on DE/FI/JP (`client connected`, id `user`). Therefore failure is not DNS/cert/password/basic UDP reachability.
- Failure mode on DE/FI/JP: after handshake, stream/data-plane stalls and disconnects with `accepting stream failed: timeout: no recent network activity`; DE also shows remote TCP timeouts during user attempts.
- Low-level comparison:
  - Hysteria version is same everywhere: `v2.9.2`.
  - SE runs Ubuntu 26.04/kernel 7.0 and Docker host-network; JP also kernel 7.0 but fails, so kernel alone is not enough.
  - UDP buffers differ: SE/DE `rmem_max/wmem_max=67108864`, JP `4194304`, FI `212992`. FI buffers should be raised later, but DE already has large buffers and still fails, so buffers are not the only cause.
- Current conclusion: HY2 works on Sweden/Veesp route, but the same HY2 profile on Hetzner/Vultr/Osaka-style nodes reaches handshake and then loses usable data-plane. This strongly points to provider/route/ASN/UDP path behavior rather than a simple HY2 config mismatch.

## 2026-06-11 - Correction: Singapore HY2 also fails
- User clarified that Singapore HY2 was also tested and is not available/does not work; previous impression was a mix-up with Sweden.
- Updated matrix: Hysteria 2 domain currently works only on Sweden/Veesp. DE/FI/JP/SG fail for the user.

## 2026-06-11 - Candidate provider selection logic after HY2/VLESS tests
- Current working baseline: Sweden/Veesp route works for HY2 on Wi-Fi and LTE, and earlier showed the strongest behavior for AWG/VLESS tests.
- Failed/currently red: Hetzner DE/FI and Vultr JP/SG for HY2/AWG/VLESS in Russia/MegaFon LTE-like tests. They may accept handshake but lose usable data-plane.
- External clues from Amnezia Premium screenshots/tests:
  - VLESS Premium worked on LTE through AdKyNet SAS / Paris egress (`163.5.175.22` seen by user).
  - User also captured ASN199412 ANARCHY LAB S.R.L. and ASN24875 NovoServe B.V. as Amnezia Premium network/server clues.
- Web/BGP notes checked 2026-06-11:
  - Veesp sells VPS in LV, NL, SE; lowest displayed VPS tier includes 1 vCore/1GB/20GB NVMe, 1Gbit, unlimited traffic, locations LV/NL/SE.
  - NovoServe AS24875 is a carrier/network in NL with many upstreams including Arelion/Telia, Cogent, Lumen, GTT, NTT, Orange; NovoServe site focuses on bare metal, EU/US data centers, speedtest/looking glass, and says free trial can be requested.
  - AS24875 peer list includes AS199412 ANARCHY LAB S.R.L.; treat Anarchy/AdKyNet as network clues, not yet confirmed easy VPS purchase targets.
- Recommended next buying order:
  1. Veesp NL VPS (same provider family as working SE, different location) - cheapest/fastest validation.
  2. Veesp LV VPS (same provider family, another route) - second cheap validation.
  3. NovoServe NL/EU trial or cheapest available bare metal/cloud option - based on Amnezia Premium/NovoServe clue, but likely more expensive; ask for trial if possible.
  4. Search/direct contact for AdKyNet/Anarchy-based hosting only after Veesp NL/LV and NovoServe are tested.
- Acceptance rule for any new node: before adding to production, run HY2 domain UDP 443 + AWG + VLESS WS/TLS; user must test Wi-Fi and LTE; reject if handshake succeeds but data-plane stalls/timeouts like DE/FI/JP/SG.
## 2026-06-11 - Simple VPN production wiring after provider cleanup

- User deleted Singapore, Japan/Osaka and Finland nodes at the hosters and asked to disable them in GRANI.
- Database change:
  - `FI-HEL-01` / `204.168.160.160` set `is_active=false`;
  - `SG-SIN-01` / `149.28.139.231` set `is_active=false`;
  - `JP-OSA-01` / `66.245.219.118` set `is_active=false`;
  - `SE-STO-01` / `13.140.9.211` remains the only active Simple VPN server;
  - Sweden `supported_protocols` set to `["vless_ws", "hysteria2", "graniwg"]`.
- Backend `/api/simple-vpn` changes:
  - `/config` now accepts `protocol` query parameter and no longer silently falls back to global `SIMPLE_VPN_PROTOCOL`;
  - `vless_ws` returns the tested Sweden VLESS WebSocket profile for the embedded Xray runtime:
    - UUID `b7f4087a-5eb5-4d5e-8d05-1d5ff93447a0`;
    - server IP `13.140.9.211`;
    - TCP `8080`;
    - WebSocket path `/grani-ws`;
    - `security=none`;
  - `hysteria2` can return the Sweden HY2 URI/metadata (`hy2-se.granilink.com:443`, password `GRANI-SE-HY2-domain-20260611`) but is marked `runtime=requires-libbox`;
  - non-WireGuard protocols no longer call server-side `wg show` verification; entitlement is still checked, but node traffic verification returns `client_side`.
- Flutter Simple VPN changes:
  - `SimpleVpnApi.fetchConfig()` now sends selected `protocol`;
  - config cache now accepts Xray configs, not only AmneziaWG;
  - selecting `vless_ws` is enabled and starts through the existing embedded Xray runtime;
  - selecting `hysteria2` is intentionally blocked in this APK with a clear runtime message because Android libbox/sing-box execution was previously removed from the app. The `libbox.aar` file exists, but the Kotlin `PlatformInterface/openTun` service lifecycle is not implemented in current runtime.
  - pre-connect cleanup now stops both AmneziaWG and legacy/Xray runtime to avoid stale tunnels when switching protocols.
- Validation:
  - backend syntax check passed: `docker exec granivpn_api python -m py_compile /app/api/simple_vpn.py`;
  - `granivpn_api` restarted and is healthy;
  - health endpoint reports `total_servers=1`, `healthy=1`;
  - targeted Dart format/analyze passed for `simple_vpn_api.dart` and `simple_vpn_controller.dart`.
- Build:
  - APK build requested by user and completed:
    - server path: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk`;
    - local output copy: `outputs/grani-release-20260611.apk`;
  - AAB build requested by user and completed:
    - server path: `/opt/grani/mobile-app/build/app/outputs/bundle/release/app-release.aab`;
    - local output copy: `outputs/grani-release-20260611.aab`.
- Important runtime caveat:
  - This build does not include a working in-app Hysteria2 tunnel runtime.
  - VLESS WS and WireGuard obf are the runnable in-app protocols in this APK/AAB.
  - Hysteria2 remains server-profile-ready, but Android app execution needs a separate restoration of libbox/sing-box `PlatformInterface.openTun()` lifecycle before exposing it as a selectable working protocol.

## 2026-06-11 - Hysteria2 in-app runtime integration build

- Implemented first in-app Hysteria2 runtime path for Android instead of only exposing external/manual HY2 links.
- Backend /api/simple-vpn/config?protocol=hysteria2 now returns sing-box JSON, not a hysteria2:// URI:
  - TUN inbound: 172.19.0.1/30, uto_route=true, strict_route=true, mtu=1280, stack=system;
  - outbound: 	ype=hysteria2, server=hy2-se.granilink.com, server_port=443, password GRANI-SE-HY2-domain-20260611, TLS SNI hy2-se.granilink.com;
  - DNS strategy is IPv4-only with Cloudflare/Google fallback.
- Flutter SimpleVpn runtime changes:
  - Hysteria2 selection is no longer blocked by the previous  requires libbox runtime guard;
  - cached configs now allow ngine=hysteria2;
  - Android runtime passes the sing-box JSON into the native VPN service with protocol hysteria2.
- Android native changes:
  - added GraniLibboxRuntime.kt wrapping local sing-box libbox.aar through CommandServer + PlatformInterface;
  - added Hysteria2 protocol detection in VpnService.kt for sing-box JSON outbounds and hysteria2:///hy2:// URIs;
  - added Hysteria2Adapter lifecycle parallel to Xray adapter;
  - openTun() creates Android VPN TUN from libbox TunOptions, with fallback address/routes.
- Build dependency fix:
  - libbox.aar and libXray both contain gomobile go.* runtime classes, causing R8 duplicate class failure (go.Seq).
  - Original ndroid/app/libs/libbox.aar was left untouched.
  - Created ndroid/app/libs/libbox-nogo.aar from the same AAR with only duplicate go/* classes removed from classes.jar.
  - uild.gradle now depends on libs/libbox-nogo.aar.
- Validation:
  - backend syntax check passed: docker exec granivpn_api python -m py_compile /app/api/simple_vpn.py;
  - granivpn_api restarted and is healthy;
  - Dart format/analyze passed for lib/simple_vpn/simple_vpn_controller.dart;
  - release APK build passed;
  - release AAB build passed.
- Build outputs:
  - server APK: /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk (~152 MB);
  - server AAB: /opt/grani/mobile-app/build/app/outputs/bundle/release/app-release.aab (~115 MB);
  - local APK copy: outputs/grani-hy2-runtime-20260611.apk, SHA256 F1ABBFA2E2C2B7ABC4A2D989199B215B117EF00A29BE97A5FA5E367662CB8F06;
  - local AAB copy: outputs/grani-hy2-runtime-20260611.aab, SHA256 B18515B85C9D8DE6ECAF8AEC145393E19CE3C611C02C037F01ECF0DEA59A5B37.
- Important caveat:
  - This is the first APK where HY2 can actually start inside GRANI through libbox.
  - Physical-device runtime still needs testing. If Hysteria2 fails on phone, next step is to inspect Android logs around GraniLibboxRuntime, Hysteria2Adapter, openTun, and libbox CommandServer startup.

## 2026-06-11 - Version 24 APK/AAB public download links prepared

- Fresh context was read before publishing links.
- Current mobile version is `1.0.4+24` (`mobile-app/pubspec.yaml`).
- Used the latest release artifacts from the HY2 runtime integration build:
  - server APK source: `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk` (~152 MB);
  - server AAB source: `/opt/grani/mobile-app/build/app/outputs/bundle/release/app-release.aab` (~115 MB).
- Published public download files:
  - `/opt/grani/server-config/static-pages/downloads/grani-vpn-1.0.4-24-hy2-runtime-20260611.apk`;
  - `/opt/grani/server-config/static-pages/downloads/grani-vpn-1.0.4-24-hy2-runtime-20260611.aab`;
  - `/opt/grani/server-config/static-pages/downloads/grani-vpn-1.0.4-24-hy2-runtime-20260611.sha256`.
- Public URLs verified with HTTP 200 via Cloudflare:
  - `https://api.granilink.com/downloads/grani-vpn-1.0.4-24-hy2-runtime-20260611.apk`;
  - `https://api.granilink.com/downloads/grani-vpn-1.0.4-24-hy2-runtime-20260611.aab`;
  - `https://api.granilink.com/downloads/grani-vpn-1.0.4-24-hy2-runtime-20260611.sha256`.
- SHA256:
  - APK `f1abbfa2e2c2b7abc4a2d989199b215b117ef00a29be97a5fa5e367662cb8f06`;
  - AAB `b18515b85c9d8de6ecaf8aec145393e19ce3c611c02c037f01ecf0dea59a5b37`.
- Note: `granilink.com/downloads/...` returned 404; the working public download host is `api.granilink.com/downloads/...`.

## 2026-06-15 - Hetzner support reply about UDP/VPN filtering

- Hetzner replied to ticket 2026061003009391 on 2026-06-12.
- Their position:
  - UDP applications are not filtered by Hetzner;
  - VPN tunnels are expected to work normally;
  - Hetzner DDoS protection does not filter such traffic;
  - the only Hetzner-side filtering they point to is a user-created Hetzner Cloud Firewall attached to the server.
- Useful conclusion:
  - This lowers the probability of a simple Hetzner product-level UDP/VPN block or DDoS rule as the root cause.
  - It does not prove the full route is clean for Russia/MegaFon LTE, because the observed failures were data-plane stalls after handshake and can still be caused by route/ASN/peering/return-path behavior outside a simple hoster firewall rule.
  - For Hetzner nodes, next diagnostic value would come only from packet-level evidence: simultaneous tcpdump on node and client-side logs/timestamps/source port, plus MTR/tracepath where possible. Without that, Hetzner will likely keep answering that no provider-side filter exists.
- Current operational conclusion remains unchanged: Sweden/Veesp is the working baseline; Hetzner DE/FI should not be trusted for production until a real Android/LTE data-plane test passes.

## 2026-06-15 - New server buying shortlist

- User asked where to buy new servers after Hetzner/Vultr/Osaka/FI/SG failures and Sweden/Veesp success.
- Recommended order:
  1. Buy Veesp Netherlands VPS first. Reason: same provider family as working Sweden, cheap VPS tier, different geography/route; official Veesp VPS locations include LV/NL/SE with 1Gbit and unlimited traffic.
  2. Buy Veesp Latvia VPS second if NL works or needs comparison. Reason: same provider family, another route, low cost.
  3. Test NovoServe Netherlands next, preferably trial/promo/budget dedicated if available. Reason: Amnezia Premium clue showed NovoServe/AS24875; NovoServe has EU/US data centers, looking glass and speedtest; likely more expensive than VPS.
  4. Search/contact AdKyNet/Anarchy only after Veesp NL/LV and NovoServe, because they are useful network clues from Premium screenshots but not yet confirmed easy VPS purchase targets.
- Avoid for now: buying more Hetzner/Vultr nodes for production. Their issue looks route/provider/ASN/data-plane related, not simple config/port failure.
- Acceptance rule for any new node before production: install GRANI stack, enable HY2 domain + VLESS WS + WireGuard obf, then user tests Wi-Fi and LTE. Accept only if Speedtest and normal browsing pass, not merely handshake/ping/packet counters.

## 2026-06-16 - Google Play unsupported / APK not installed on Redmi 9A

- User reported Google Play says the app is not supported on Redmi 9A, and direct APK install shows Приложение не установлено.
- Device screenshot: Redmi 9A, MIUI Global 12.5.7, Android 11.
- Checked current Android Gradle config:
  - ndroid/app/build.gradle has biFilters 'arm64-v8a';
  - packaging excludes lib/armeabi-v7a/**, lib/x86/**, lib/x86_64/**;
  - comment says only arm64-v8a was left to reduce APK size.
- Current native libraries can support 32-bit ARM:
  - libXray.aar: arm64-v8a, armeabi-v7a, x86, x86_64;
  - libbox.aar: arm64-v8a, armeabi-v7a, x86, x86_64;
  - libbox-nogo.aar: arm64-v8a, armeabi-v7a, x86, x86_64;
  - ndroid/app/src/main/jniLibs/armeabi-v7a/libxray.so also exists.
- Most likely cause:
  - Redmi 9A/MIUI Android 11 may run 32-bit Android userspace even on capable hardware;
  - current Play artifact/APK only allows arm64-v8a, so Google Play marks it unsupported and APK installer rejects it as incompatible.
- Fix plan:
  - remove/rework biFilters 'arm64-v8a';
  - stop excluding lib/armeabi-v7a/**;
  - keep excluding x86/x86_64 if we only want phones;
  - rebuild APK/AAB after explicit user command to build;
  - upload new AAB to Play so Google can serve armeabi-v7a devices.

## 2026-06-16 - Test APK with armeabi-v7a support for Redmi 9A

- User asked to build a test APK after Google Play/direct APK install failed on Redmi 9A.
- Change made in ndroid/app/build.gradle:
  - replaced biFilters 'arm64-v8a' with biFilters 'arm64-v8a', 'armeabi-v7a';
  - removed packaging exclusion of lib/armeabi-v7a/**;
  - kept x86/x86_64 exclusions.
- Built release APK only, no AAB requested in this step:
  - server path: /opt/grani/mobile-app/build/app/outputs/flutter-apk/app-release.apk;
  - size on server: ~280 MB.
- Verified APK native libraries now include both phone ARM ABIs:
  - lib/arm64-v8a/...;
  - lib/armeabi-v7a/....
- Local test APK copy:
  - outputs/grani-v24-hy2-runtime-arm32-test-20260616.apk;
  - SHA256 57EE206B4106F9AE2E15F7C4BCE4F07E870B74DF48B8650881A546AEF12DDC49.
- Expected effect:
  - Redmi 9A / 32-bit Android userspace devices should no longer be rejected due to ABI incompatibility.
  - If direct install still fails, next diagnostics should inspect Android package installer reason via db install output or logcat PackageInstaller messages.

## 2026-06-16 - Runtime test logs on 32-bit Redmi 9A APK

- User tested the latest arm32-capable APK on Redmi 9A / 32-bit Android userspace with all three protocols.
- Local log source: C:\\Users\\railt\\Desktop\\логи.txt.
- Android VPN permission prompt timing:
  - First native VPN call reached VpnPlugin at 15:14:31.712;
  - Android permission request was issued at 15:14:31.930;
  - user allowed it at 15:14:35.680.
  - Conclusion: native permission request is almost immediate once native connect starts. Any visible delay before the system dialog is caused by Flutter/backend preparation before native connect: cleanup, config fetch, session start, and especially WireGuard config failures that wait 7-9 seconds.
- VLESS WS result:
  - Xray itself starts and reaches LOCAL_UP, but the separate com.granivpn.mobile:tun2socks process crashes on 32-bit:
    java.lang.UnsatisfiedLinkError: dlopen failed: library  libtun2socks.so not found.
  - APK inspection confirms lib/arm64-v8a/libtun2socks.so exists, but lib/armeabi-v7a/libtun2socks.so is missing.
  - Root cause found in ndroid/third_party/tun2socks/build.gradle: 
dk { abiFilters arm64-v8a } still restricts tun2socks to arm64 even though the main app now allows rmeabi-v7a.
  - Practical effect: VLESS may show connected, but real TUN traffic cannot pass on 32-bit, so YouTube/browsing fails.
  - Next fix: add rmeabi-v7a to tun2socks ABI filters and rebuild APK/AAB after explicit build command.
- Hysteria2 result:
  - App crashes during GraniLibboxRuntime.start / Hysteria2Adapter.
  - Crash: No implementation found for void io.nekohasekai.libbox.Libbox._init().
  - Likely root cause: libXray and libbox are both gomobile-based and both depend on libgojni.so / Go Java runtime. R8 duplicate Java classes were worked around with libbox-nogo.aar, but APK can still contain only one libgojni.so per ABI, effectively leaving libbox Java without the native _init symbol it expects.
  - Short-term safe action: do not expose Hysteria2 as selectable in production APK until moved to a separate runtime path; otherwise it crashes on both 32-bit and 64-bit.
  - Longer-term options: run HY2 via separate native executable/sing-box binary, or isolate/rebuild gomobile runtime so libbox and libXray do not collide.
- WireGuard obf / GRANIwg result:
  - Phone logs do not show a real connectAmneziaWg start for the failing attempt.
  - Backend logs show /api/simple-vpn/config returns 500 after 7-9 seconds because server 5 cannot reload WireGuard:
    Failed to add AmneziaWG peer on server / Не удалось перезагрузить WireGuard на сервере 5.
  - Root cause is currently server-side on Sweden node AWG/WG reload path, not Android VPN permission or client UI.
  - Next diagnostic: inspect Sweden node WireGuard/AWG service, reload command, journal, and config syntax before trying more client changes.
- Other app observations:
  - Startup on Redmi 9A is heavy: Activity onStart took 2373ms, Skipped 193 frames; likely too much main-thread startup/bootstrap work for low-end devices.
  - ConnectionLogger initially flushed with stale device id 1b59958f-eeb8-4a98-a853-6b86ed3d5805, then later with valid 53b6f1b-eb9f-4b93-975c-d6f475175065. This is not the protocol failure root cause, but pollutes diagnostics and should be cleaned up by aligning/clearing legacy logger device id after login/device resolve.
  - Repeated BASE URL logs are noisy and should be reduced in release diagnostics.

## 2026-06-16 - Deeper Hysteria2/libbox crash analysis

- Re-examined the HY2 crash: No implementation found for void io.nekohasekai.libbox.Libbox._init().
- Important correction to the previous short hypothesis:
  - libbox.so is present in both the original ndroid/app/libs/libbox.aar and the final APK for arm64-v8a and armeabi-v7a.
  - eadelf -Ws confirms Java_io_nekohasekai_libbox_Libbox__1init exists inside libbox.so for both arm64 and armeabi-v7a.
  - Therefore the symbol was not stripped and the native library is not missing from the APK.
- Actual mechanism found by inspecting generated Java bytecode:
  - io.nekohasekai.libbox.Libbox.<clinit> does only:
    1. go.Seq.touch();
    2. Libbox._init().
  - Original libbox go.Seq.<clinit> loads System.loadLibrary( box) and then calls go.Seq.init().
  - Xray go.Seq.<clinit> loads System.loadLibrary(gojni) and then calls go.Seq.init().
  - Current app depends on libbox-nogo.aar, where go/* classes were removed to bypass duplicate go.Seq / go.Universe classes with libXray.
  - As a result, the app uses Xray's go.Seq, not libbox's go.Seq.
  - When Hysteria2 starts, Libbox.<clinit> calls Xray's go.Seq.touch(), which loads libgojni.so, not libbox.so; then Libbox._init() runs while libbox.so has not been loaded by the expected gomobile path, so Android reports no implementation for _init.
- This is a gomobile runtime collision, not a Hysteria/network/server issue.
- Quick diagnostic option:
  - Explicitly call System.loadLibrary(box) before the first reference to Libbox in GraniLibboxRuntime.setupIfNeeded.
  - This may remove the immediate _init crash because the symbol exists in libbox.so.
  - Risk: it may still be unstable because libbox's own go.Seq.init() will not run through its original generated class; Xray's go.Seq remains the only Java Go runtime class in the app.
- Cleaner architectural options:
  1. Prefer one Go/gomobile runtime in the app. Use sing-box/libbox for both VLESS WS and HY2 instead of mixing libXray and libbox.
  2. Or run HY2/sing-box as an isolated native executable/service path rather than gomobile AAR Java bindings.
  3. Or build one combined gomobile AAR containing all required Go packages in one native library/runtime, if feasible.
  4. Separate Android process alone is probably not enough while the APK classpath still contains only Xray's go.Seq.
- Recommended next action:
  - For immediate experiment, patch explicit System.loadLibrary(box), rebuild APK, and test whether the crash moves further or HY2 starts.
  - For production, plan migration away from simultaneous libXray + libbox gomobile AARs in one classpath.

## 2026-06-16 - Hysteria2 moved away from libbox/gomobile collision

- User chose the clean HY2 direction: run Hysteria2 as a separate native executable/runtime, then return to VLESS and WireGuard later.
- Goal of this pass: stop using libbox/gomobile Java bindings for HY2 because they collide with libXray's gomobile runtime/classes and caused:
  - No implementation found for void io.nekohasekai.libbox.Libbox._init().
- Implemented new HY2 Android runtime path:
  - added android/app/src/main/kotlin/com/granivpn/mobile/Hysteria2ProcessWrapper.kt;
  - HY2 now starts the official Hysteria Android native executable as a child process;
  - HY2 process listens on local SOCKS 127.0.0.1:10818;
  - Android VpnService creates TUN and uses the existing Tun2SocksProcessService bridge to route TUN -> HY2 SOCKS;
  - this avoids libbox Java/gomobile bindings entirely for Hysteria2.
- Official Hysteria v2.9.2 Android executables were downloaded from GitHub release and installed as packaged native executables:
  - arm64-v8a: android/app/src/main/jniLibs/arm64-v8a/libhysteria2.so;
  - armeabi-v7a: android/app/src/main/jniLibs/armeabi-v7a/libhysteria2.so.
- Verified release hashes against GitHub checksums:
  - arm64 sha256 0d8511d0e9ab5162a38e41cae90e470a1a109591a35d5e19226d781629cb5917;
  - armv7 sha256 9a8c4cd7cac4d0d3bc0f90380bda779f1600f9662eacc4bda09701a837e61aea.
- Hysteria2ProcessWrapper supports these input formats from backend/app config:
  - hysteria2:// or hy2:// URI;
  - sing-box JSON outbound with type=hysteria2;
  - existing YAML with server/auth/tls/obfs fields.
- Generated runtime YAML includes:
  - server, auth;
  - tls.sni and tls.insecure;
  - obfs salamander/gecko when present;
  - quic.disablePathMTUDiscovery=true;
  - socks5.listen=127.0.0.1:10818.
- Updated android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt:
  - Hysteria2Adapter now uses Hysteria2ProcessWrapper instead of GraniLibboxRuntime;
  - stop/onDestroy paths now stop the process runtime cleanly;
  - runtime failure is reported as Hysteria2 process stopped.
- Updated android/app/build.gradle:
  - packaging.jniLibs.useLegacyPackaging=true;
  - keepDebugSymbols includes **/libhysteria2.so so Gradle does not strip/break the packaged executables.
- Updated android/third_party/tun2socks/build.gradle:
  - added armeabi-v7a to tun2socks ABI filters;
  - this is required because the HY2 process path uses the same tun2socks bridge, and it also fixes the previously observed 32-bit missing libtun2socks.so class of failures for bridge-based protocols.
- Verification run on server, no APK/AAB build in this pass:
  - cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin --no-daemon --stacktrace -> BUILD SUCCESSFUL;
  - cd /opt/grani/mobile-app/android && ./gradlew :tun2socks:externalNativeBuildRelease --no-daemon -> BUILD SUCCESSFUL;
  - native build produced both arm64-v8a and armeabi-v7a tun2socks artifacts.
- Important caveat:
  - Device behavior is not yet verified because APK/AAB was not built in this step.
  - libbox files/classes remain in the tree for now but HY2 no longer uses GraniLibboxRuntime. Do not remove libbox until after device test confirms the new HY2 process path works.
- Next when user explicitly asks to build:
  - build APK/AAB;
  - install on 64-bit and 32-bit devices;
  - test HY2 first for absence of libbox _init crash;
  - then test actual traffic through the HY2 local SOCKS + tun2socks path;
  - after HY2 is stable, return to VLESS and WireGuard server-side issues.

## 2026-06-16 - Returned to VLESS and WireGuard after HY2 process-runtime work

- User asked to return to VLESS and WireGuard problems.
- Current active server state in DB:
  - active: server 5 SE-STO-01 / Sweden / 13.140.9.211;
  - inactive: HU/UK/IE legacy, DE/FI/SG/JP test nodes. DE/FI/SG/JP are no longer offered by /api/simple-vpn/servers.
- VLESS WS status:
  - backend /api/simple-vpn/config for protocol=vless_ws still returns the tested Sweden plain WS profile: 13.140.9.211:8080, path /grani-ws, UUID b7f4087a-5eb5-4d5e-8d05-1d5ff93447a0;
  - the latest confirmed Android 32-bit failure was client-side bridge failure: missing armeabi-v7a libtun2socks.so;
  - this was already addressed by adding armeabi-v7a to android/third_party/tun2socks/build.gradle during the HY2 process-runtime pass, because both HY2-process and VLESS use the same TUN -> tun2socks bridge;
  - this VLESS fix requires a new APK/AAB before the user can validate it on Redmi 9A / 32-bit userspace.
- WireGuard obf / AmneziaWG status before fix:
  - backend logs showed /api/simple-vpn/config returned 500 because server 5 reload failed;
  - direct node diagnostics through backend SSH confirmed Sweden wg0 was not running and no UDP listener existed on 51820;
  - /etc/amnezia/amneziawg/wg0.conf was corrupted with orphan peer fragments: comments and AllowedIPs outside [Peer] blocks, plus an incomplete trailing [Peer] with PublicKey but no AllowedIPs;
  - RemoteVPNManager.reload_wireguard also always used wg-quick, while Sweden is an AmneziaWG node with awg/awg-quick installed and awg-quick@.service enabled.
- Backend fix applied in backend/infrastructure/external/remote_vpn_manager.py:
  - _dedupe_wireguard_peers now removes orphan peer-only keys from the interface/header area;
  - malformed peer blocks without both PublicKey and AllowedIPs are dropped;
  - adjacent peer blocks are flushed correctly before a new [Peer];
  - reload_wireguard now chooses awg-quick when awg-quick exists and the config contains AmneziaWG fields Jc/Jmin/Jmax/H1-H4 or the config path is under /amnezia/;
  - reload failures now log stdout/stderr for the remote command.
- Server fix applied on Sweden:
  - backup created: /etc/amnezia/amneziawg/wg0.conf.grani-backup-20260616-135115;
  - config normalized from 1387 bytes to 839 bytes;
  - valid peer blocks after cleanup: 3;
  - awg reload succeeded.
- Verification:
  - docker exec granivpn_api python -m py_compile /app/infrastructure/external/remote_vpn_manager.py passed;
  - granivpn_api restarted and is healthy;
  - Sweden wg0 is now UP, listening on UDP 51820, with AWG fields jc=4/jmin=5/jmax=60/h1=1/h2=2/h3=3/h4=4;
  - iptables now includes wg0 FORWARD rules and 10.0.0.0/24 MASQUERADE via eth0.
- Expected effect:
  - WireGuard obf config requests should no longer fail with 500 from server 5 reload;
  - VLESS on 32-bit devices still needs a freshly built APK/AAB to include armeabi-v7a tun2socks.
- Remaining checks after next APK/AAB build:
  - test VLESS WS on 32-bit Redmi 9A: it should no longer crash/fail due missing libtun2socks.so;
  - test WireGuard obf on Sweden: backend should issue config, node should add peer, and wg0 should show traffic/handshake.
## 2026-06-16 - Log review after APK test: early VPN permission + VLESS bridge failure reporting

- User asked to re-check the attached Android logs and identify unfinished pieces, especially why the Android system VPN permission prompt appears late.
- Log timing:
  - first VLESS connect reached native `VpnPlugin.connect` at `2026-06-16 15:14:31.828`;
  - native permission request was logged at `15:14:31.930`;
  - user allowed the permission at `15:14:35.680`.
  - Therefore native permission prompt itself was requested about 100 ms after native connect. The perceived delay was before native connect: Flutter did preconnect cleanup, options/config/session/device work first.
- Implemented early permission request in Flutter before backend/config work:
  - `lib/services/native_vpn_service.dart`: added `NativeVpnService.requestPermission()`;
  - `lib/simple_vpn/simple_vpn_controller.dart`: added `SimpleVpnRuntime.requestPermission()` and call it near the beginning of `connect()`, with UI progress `Запрашиваем разрешение VPN...`;
  - Android runtime delegates to native `requestPermission`; non-Android/unsupported runtimes return true.
  - Expected effect in next APK: first Android system VPN prompt should appear immediately after pressing connect, before long backend/config preparation.
- VLESS 32-bit failure from logs:
  - process `com.granivpn.mobile:tun2socks` crashed with `UnsatisfiedLinkError: dlopen failed: library "libtun2socks.so" not found`;
  - this confirms the old APK did not include/provide 32-bit `armeabi-v7a` `libtun2socks.so`;
  - ABI packaging was already changed in the prior HY2 process-runtime pass by adding `armeabi-v7a` to `android/third_party/tun2socks/build.gradle`, so this part needs a fresh APK/AAB to validate.
- Additional VLESS bug found in the same logs:
  - after the `tun2socks` process crashed, the main process logged `tun2socks_service_disconnected`;
  - then `XrayNativeWrapperTun2Socks` suppressed that failure inside the 7s grace window:
    `suppress tun2socks failure in grace window elapsed_ms=2226 reason=tun2socks_service_disconnected`;
  - result: UI could stay effectively connected/committed while the traffic bridge was dead.
- Implemented narrow native fix:
  - `android/app/src/main/kotlin/com/granivpn/mobile/XrayNativeWrapperTun2Socks.kt`;
  - if `reason == "tun2socks_service_disconnected"` and `lastTunState == "attached"`, report failure immediately via `onTun2SocksFailure` instead of suppressing it in the grace window.
  - Expected effect in next APK: if VLESS/HY2 bridge dies after attach, UI/backend should see a real connection failure instead of silently showing connected.
- Hysteria2 in the old phone logs:
  - the crash `No implementation found for void io.nekohasekai.libbox.Libbox._init()` belongs to the pre-fix APK path using libbox/gomobile;
  - project source now has the new separate Hysteria2 process runtime, but it still needs a fresh APK/AAB device test.
- Other log observations / remaining debt:
  - Redmi 9A startup is heavy: `onStart took 2373ms`, `Skipped 193 frames`, later `onLayout time too long`;
  - Google OAuth/navigation path was slow on this device, with `start_screen_navigation_done total_ms=26126`;
  - noisy repeated `BASE URL` logs and Google/Billing binder warnings remain cleanup/performance debt, not the immediate protocol failure.
- Verification:
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter analyze lib/simple_vpn/simple_vpn_controller.dart lib/services/native_vpn_service.dart --no-fatal-infos --no-fatal-warnings` passed with only existing info-level `use_super_parameters`;
  - `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin --no-daemon --stacktrace` passed: `BUILD SUCCESSFUL`;
  - no APK/AAB build was run in this pass.

## 2026-06-16 - Built separate 32-bit and 64-bit APKs after permission/VLESS/HY2 fixes

- User explicitly asked to build APKs for both 64-bit and 32-bit app versions.
- First command attempted:
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release --split-per-abi`;
  - failed because Flutter split ABI configuration included `x86_64`, while app `ndk.abiFilters` allowed only `armeabi-v7a,arm64-v8a`.
- Second command attempted:
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64`;
  - also failed because Gradle does not allow `ndk.abiFilters` and ABI splits to be active at the same time, even when the ABI list matches.
- Applied minimal Gradle build fix in `android/app/build.gradle`:
  - wrapped `defaultConfig.ndk.abiFilters 'arm64-v8a', 'armeabi-v7a'` in:
    `if (!project.hasProperty("graniSplitPerAbi")) { ... }`;
  - normal non-split builds keep the existing ABI filter;
  - split builds can pass `ORG_GRADLE_PROJECT_graniSplitPerAbi=true` so Flutter/Gradle owns the ABI split.
- Successful build command:
  - `cd /opt/grani/mobile-app && ORG_GRADLE_PROJECT_graniSplitPerAbi=true /opt/flutter/bin/flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64`;
  - build completed successfully.
- Server APK outputs:
  - `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`;
  - `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`.
- Local copied APK outputs:
  - `outputs/grani-vpn-1.0.4-v24-20260616-32bit-armeabi-v7a.apk`;
  - `outputs/grani-vpn-1.0.4-v24-20260616-64bit-arm64-v8a.apk`.
- Sizes and hashes:
  - 32-bit `armeabi-v7a`: 74,423,037 bytes, SHA256 `dc58fe68898f3b3c3273716dcd5f3ca8c952453da3e17e7ffde6ea9df0532d6a`;
  - 64-bit `arm64-v8a`: 73,223,895 bytes, SHA256 `4ed6a08d76594b25fec8a23694b65b237cbaa15d934ada13cce0f33252a1fe9c`.
- APK native library checks:
  - 32-bit APK contains:
    - `lib/armeabi-v7a/libtun2socks.so`;
    - `lib/armeabi-v7a/libhysteria2.so`;
    - `lib/armeabi-v7a/libwg-go.so`;
    - `lib/armeabi-v7a/libgojni.so`;
    - `lib/armeabi-v7a/libxray.so`.
  - 64-bit APK contains:
    - `lib/arm64-v8a/libtun2socks.so`;
    - `lib/arm64-v8a/libhysteria2.so`;
    - `lib/arm64-v8a/libwg-go.so`;
    - `lib/arm64-v8a/libgojni.so`;
    - `lib/arm64-v8a/libxray.so`.
- What to test on devices:
  - 32-bit Redmi 9A: VLESS should no longer crash with missing `libtun2socks.so`;
  - 32-bit and 64-bit: HY2 should no longer crash with old libbox `_init` because the app now uses separate Hysteria2 process runtime;
  - WireGuard obf on Sweden should request config successfully and avoid the previous server-side 500/reload failure.

## 2026-06-16 - Published 32-bit APK download link

- User asked for a phone-downloadable link for the 32-bit APK.
- Copied server build artifact:
  - from `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`;
  - to `/opt/grani/server-config/static-pages/downloads/grani-vpn-v24-32bit.apk`.
- Public URL verified:
  - `https://api.granilink.com/downloads/grani-vpn-v24-32bit.apk`;
  - HTTP/2 200;
  - `content-type: application/vnd.android.package-archive`;
  - `content-length: 74423037`;
  - `content-disposition: attachment`;
  - `cache-control: no-store`.
- SHA256:
  - `dc58fe68898f3b3c3273716dcd5f3ca8c952453da3e17e7ffde6ea9df0532d6a`.
- Note:
  - `https://granilink.com/downloads/grani-vpn-v24-32bit.apk` currently returns 404, so use the `api.granilink.com` download URL.

## 2026-06-16 - Launcher icon foreground horizontal centering fix

- User reported that on the installed 32-bit APK the launcher icon looks wrong: the `G` is shifted right relative to the white adaptive icon background.
- Checked Android icon configuration:
  - `AndroidManifest.xml` uses `android:icon="@mipmap/ic_launcher"`;
  - Android 8+ uses adaptive icon `android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml`;
  - adaptive icon is white background `@color/ic_launcher_background` + foreground `@drawable/ic_launcher_foreground`.
- Root cause:
  - not ABI-specific and not a 32-bit runtime issue;
  - the source adaptive foreground PNGs were horizontally off-center inside their transparent canvases.
- Measured alpha bounding boxes before fix:
  - mdpi `108x108`: `dx=+6.0 px`;
  - hdpi `162x162`: `dx=+8.5 px`;
  - xhdpi `216x216`: `dx=+11.5 px`;
  - xxhdpi `324x324`: `dx=+17.5 px`;
  - xxxhdpi `432x432`: `dx=+24.0 px`.
  - Positive dx means the visible `G` was shifted right relative to the canvas center.
- Fixed files by shifting the foreground artwork left per density:
  - `android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png`;
  - `android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png`;
  - `android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground.png`;
  - `android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png`;
  - `android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png`.
- Server-side verification after fix:
  - mdpi `dx=0.0 px`;
  - hdpi `dx=+0.5 px`;
  - xhdpi `dx=-0.5 px`;
  - xxhdpi `dx=-0.5 px`;
  - xxxhdpi `dx=0.0 px`.
  - Half-pixel offsets are expected where bbox/canvas parity differs.
- Important:
  - the already published APK at `https://api.granilink.com/downloads/grani-vpn-v24-32bit.apk` still contains the old icon;
  - a fresh APK rebuild and re-publish is required before the phone shows the centered launcher icon.

## 2026-06-16 - Post-test node check + protocol UI/status fixes

- User tested the fresh app build:
  - VLESS WS connected successfully;
  - Hysteria 2 failed;
  - WireGuard obf failed;
  - also reported UI bug: if the phone already has some other VPN active before opening GRANI, the main button can show connected, but it must show connected only for GRANI's own VPN.
- Backend/API log review around the test:
  - VLESS WS on Sweden/server_id=5 issued config and started sessions normally;
  - VLESS produced client-side verify events and repeated verification for session `e4e83edf-0654-4b33-92d2-64d056be5747`;
  - one transient verify call had `Connection reset by peer`, then attempt 2 verified;
  - Hysteria 2 configs/session starts were accepted by backend, but API log tail did not show a matching stable `native_start_ok`, so the next suspect is Android/runtime start path or client logcat, not backend config issue;
  - WireGuard obf config was issued for Sweden/server_id=5 with prepared peer vpn_ip `10.0.0.5`, but after user stop the later verify returned `peer_not_found`. This may be stop cleanup timing, but needs another live test while still connected if WireGuard remains suspicious.
- Sweden node check:
  - host reachable via backend node SSH;
  - VLESS/Xray listens on TCP `8080`;
  - Hysteria listens on UDP `443`;
  - WireGuard obf/AmneziaWG listens on UDP `51820`;
  - `awg show wg0` shows interface up with AWG fields `jc=4/jmin=5/jmax=60/h1=1/h2=2/h3=3/h4=4`;
  - current peers on node are only old `10.0.0.2/3/4`; the test peer `10.0.0.5` was absent by the time the check ran, matching backend verify after stop.
- Fixed Android status ownership bug:
  - file: `/opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnPlugin.kt`;
  - `getAmneziaWgStatus` path no longer treats generic Android `TRANSPORT_VPN` as GRANI connection;
  - `isAmneziaWgConnected()` now returns only `SimpleAmneziaWgRunner.isUp()`;
  - expected effect: opening GRANI while another VPN is active should not set the GRANI button to connected.
- Fixed protocol sheet labels/icons:
  - file: `/opt/grani/mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`;
  - VLESS WS icon: `Icons.language`;
  - Hysteria 2 icon: `Icons.speed`;
  - WireGuard obf icon: `Icons.shield_outlined`;
  - rows no longer all use the same WireGuard subtitle.
- Added localized protocol descriptions:
  - files: `/opt/grani/mobile-app/lib/l10n/app_ru.arb`, `/opt/grani/mobile-app/lib/l10n/app_en.arb`;
  - generated localization files updated via `/opt/flutter/bin/flutter gen-l10n`;
  - RU:
    - VLESS WS: `TCP/WebSocket для сетей, где UDP режется`;
    - Hysteria 2: `QUIC-туннель для нестабильных LTE/Wi-Fi`;
    - WireGuard obf: `Быстрый WireGuard с маскировкой`;
    - fallback: `Альтернативный маршрут подключения`.
  - EN:
    - VLESS WS: `TCP/WebSocket for networks blocking UDP`;
    - Hysteria 2: `QUIC tunnel for unstable LTE/Wi-Fi`;
    - WireGuard obf: `Fast WireGuard with obfuscation`;
    - fallback: `Alternative connection route`.
- Verification:
  - `/opt/flutter/bin/flutter gen-l10n` succeeded;
  - `/opt/flutter/bin/dart format lib/screens/main/clean_amnezia_home_screen.dart lib/l10n/app_localizations.dart lib/l10n/app_localizations_en.dart lib/l10n/app_localizations_ru.dart` succeeded;
  - `/opt/flutter/bin/flutter analyze lib/screens/main/clean_amnezia_home_screen.dart lib/services/native_vpn_service.dart lib/simple_vpn/simple_vpn_controller.dart --no-fatal-infos --no-fatal-warnings` completed with only existing info-level `use_super_parameters` notes in `native_vpn_service.dart`;
  - `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin --no-daemon --stacktrace` succeeded;
  - `docker ps` shows `granivpn_api` healthy and core containers up.
- No APK/AAB build was run in this pass.
## 2026-06-16 - 32-bit post-test protocol recovery: WireGuard peer sync + Hysteria obfs

- User tested the 32-bit APK:
  - crashes stopped;
  - app can still visually/background-minimize during VPN connect;
  - VLESS works;
  - Hysteria 2 does not connect;
  - WireGuard/GRANIwg stopped connecting and became the most worrying protocol.
- Log/backend review:
  - VLESS has repeated `native_start_ok` and verify events, so the 32-bit `libtun2socks.so` packaging fix is validated by user behavior;
  - Hysteria 2 backend config/session start events exist, but no stable `native_start_ok` was logged, so Android runtime/config remained suspect;
  - WireGuard config path had a prepared DB peer for the user device:
    - device UUID `f53b6f1b-eb9f-4b93-975c-d6f475175065`;
    - peer id `34`;
    - public key `40VRDog2bIUAPpE1eVaM59Y8snCehoepdVV1Vnlqw2s=`;
    - vpn ip `10.0.0.5`.
  - Before the fix, Sweden node `awg show wg0 dump` had only old peers `10.0.0.2/3/4`; runtime and config were missing `10.0.0.5`, while DB still believed it was prepared.
- WireGuard backend fixes:
  - `backend/api/simple_vpn.py`:
    - added `_restore_prepared_peer_if_missing`;
    - on graniwg prepared-peer cache hit, backend now checks runtime via `_verify_graniwg_node_traffic`;
    - if runtime returns `peer_not_found`, backend re-adds the peer to the node and marks config source as `prepared-peer-restored`;
    - normal cache hit remains `prepared-peer-cache`.
  - `backend/infrastructure/external/remote_vpn_manager.py`:
    - root cause found: full `awg-quick down/up` after writing a new peer could overwrite the just-uploaded config with old runtime state, losing the new peer;
    - `add_wireguard_peer` now writes config, then applies the peer to the live interface using `awg set`/`wg set` instead of full reload;
    - `update_wireguard_config` tries atomic upload first, but falls back to direct upload because Sweden SFTP rename returned `Failure` for `/etc/amnezia/amneziawg/wg0.conf`;
    - this avoids interface interruption and avoids losing newly added peers.
- WireGuard verification after fix:
  - backend py_compile passed for `/app/api/simple_vpn.py` and `/app/infrastructure/external/remote_vpn_manager.py`;
  - `granivpn_api` restarted and healthy;
  - marker write test confirmed direct-upload fallback writes and restores `/etc/amnezia/amneziawg/wg0.conf`;
  - final Sweden node check:
    - `awg show wg0 dump` contains `40VRDog2bIUAPpE1eVaM59Y8snCehoepdVV1Vnlqw2s= ... 10.0.0.5/32`;
    - `/etc/amnezia/amneziawg/wg0.conf` contains the peer block for `10.0.0.5`;
    - peer block count in config is now 4.
- Hysteria 2 server/config fix:
  - Sweden HY2 active server config is `/opt/grani-hy2-domain/server-granilink-salamander.yaml`;
  - it requires:
    - auth password `GRANI-SE-HY2-domain-20260611`;
    - `obfs.type = salamander`;
    - salamander password `GRANI-SE-HY2-salamander-20260611`.
  - backend previously returned Hysteria config without obfs, which explains Hysteria failing to connect.
  - `backend/api/simple_vpn.py` now adds salamander obfs for server 5:
    - `obfs: { type: "salamander", password: "GRANI-SE-HY2-salamander-20260611" }`;
    - `json_config.runtime` changed from stale `libbox` to `hysteria2-process`;
    - revision now includes `obfs:salamander`.
  - Verified generated HY2 outbound now contains:
    - server `hy2-se.granilink.com`;
    - port `443`;
    - password `GRANI-SE-HY2-domain-20260611`;
    - TLS SNI `hy2-se.granilink.com`;
    - salamander obfs password.
- Client cache protection:
  - `mobile-app/lib/simple_vpn/simple_vpn_controller.dart` now bypasses/removes cached config for `hysteria2` before connect;
  - reason: installed app could otherwise reuse old cached HY2 config without obfs even after backend fix;
  - this source change requires a new APK to affect installed clients. Without a new APK, user can still force fresh HY2 config by clearing app data/reinstalling.
- App minimizing check:
  - searched Android code for explicit `moveTaskToBack`, `finishAndRemoveTask`, HOME intents during connect;
  - no explicit app-minimize code found in active connect path;
  - `ACTION_MAIN/CATEGORY_LAUNCHER` in `VpnPlugin.kt` belongs to installed-app listing for split tunnel, not connect.
  - Current likely causes are Android VPN permission UI / switching from another active VPN / low-memory task behavior on Redmi 9A; needs logcat around the next connect if it persists.
- Verification:
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/dart format lib/simple_vpn/simple_vpn_controller.dart` completed with 0 changes after upload;
  - targeted Flutter analyze completed with no errors, only existing `use_super_parameters` info notes in `native_vpn_service.dart`;
  - no APK/AAB build was run in this pass.
- Next tests:
  - WireGuard/GRANIwg on Sweden should no longer fail with `peer_not_found`; test connect and verify traffic/handshake;
  - Hysteria 2 should be re-tested after either clearing app data/reinstalling the current APK (to drop cached old HY2 config) or building/installing a fresh APK with the cache-bypass client patch;
  - if app still minimizes during connect, collect logcat covering button tap -> permission prompt -> VPN service start.
## 2026-06-16 — APK/AAB size reduction to under 100 MB

Goal from Rail: reduce the release build size from roughly 180 MB / oversized output toward 100 MB, then build APK and AAB.

Actions:
- Removed the active `libbox-nogo.aar` dependency from `mobile-app/android/app/build.gradle`.
- Moved the unused legacy `GraniLibboxRuntime.kt` out of Kotlin compilation by renaming it to `.disabled`; active Hysteria2 path remains `Hysteria2ProcessWrapper + libhysteria2.so`.
- Kept `libhysteria2.so` debug-symbol protection because it is packaged as an executable native binary.
- Added release build flags support:
  - `graniAbiFilters` for explicit ABI filtering.
  - `graniExcludeArmv7` for Play AAB arm64-only packaging.
- Built clean release split APKs and Play AAB with Flutter tree-shaken icons and split debug info.

Resulting artifacts:
- `/opt/grani/granivpn-1.0.4+24-arm64-release.apk`
  - 51,141,530 bytes / 48.8 MiB
  - sha256 `bc775749186ecf597c96b7ed0354b907bd2ece8026e8bb528d2083b3d9606345`
- `/opt/grani/granivpn-1.0.4+24-armeabi-v7a-release.apk`
  - 52,463,042 bytes / 50.0 MiB
  - sha256 `0e7d73de864927fb427455fc45dfad995924ec971d6112a4941d47d313dba2ea`
- `/opt/grani/granivpn-1.0.4+24-play-arm64-release.aab`
  - 83,741,920 bytes / 79.9 MiB
  - sha256 `e023cc5320d56d87076665076ab331ed2b8beb022b30549b723576b86104528e`

Verification:
- Play AAB contains `base/lib/arm64-v8a`.
- Play AAB does not contain `base/lib/armeabi-v7a`.
- Play AAB does not contain `libbox.so`.
- `libgojni.so` still remains; it is pulled by the active Xray/Go runtime path, not by removed `libbox`.

Important build commands:
```bash
cd /opt/grani/mobile-app
/opt/flutter/bin/flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64 --android-project-arg=graniSplitPerAbi=true --split-debug-info=build/symbols/release-24
/opt/flutter/bin/flutter build appbundle --release --target-platform android-arm64 --android-project-arg=graniAbiFilters=arm64-v8a --android-project-arg=graniExcludeArmv7=true --split-debug-info=build/symbols/release-24-arm64-play
```

Conclusion:
- Direct APK distribution target under 100 MB is achieved for both 64-bit and 32-bit APKs.
- Google Play AAB target under 100 MB is achieved with arm64-only Play bundle.
- Do not use universal APK as the main artifact; it naturally becomes large because it packs multiple ABI native VPN runtimes.
## 2026-06-17 — защита от самопроизвольных отключений VPN

Проблема: у пользователя было два отключения VPN, одно выглядело как отключение "по подписке", второе без понятной причины. Зафиксирована политика: активный VPN нельзя отключать самопроизвольно из-за временного сбоя sync/check/verify. Остановка допустима только по явной инициации пользователя, окончанию подписки/триала, logout/auth lost/device revoke/device limit или другому явно разрешенному служебному stop-событию.

Что изменено:

- `EntitlementPushContract`: `grani_action=stop_vpn` теперь приводит к остановке VPN только если `reason` входит в allow-list (`subscription_expired`, `subscription_revoked`, `trial_ended`, `access_expired`, `logout`, `auth_lost`, `device_limit`, `device_revoked`). Любой stop_vpn без разрешенной причины только запускает refresh доступа, но не останавливает туннель.
- `EntitlementFcmReceiver`: native FCM stop_vpn получил такой же allow-list. Пакеты с пустой/неизвестной причиной логируются как проигнорированные и не вызывают stopForeground/stopVpn.
- `AppSessionController`: при resume/sync и попадании в paywall активный VPN больше не отключается. UI/Quick Tile обновляются, но туннель остается живым до явного служебного stop-события.
- `VpnOperationGuards` + `ConnectDisconnectFacade`: добавлен общий guard для disconnect. Непользовательская остановка разрешена только для allow-listed служебных причин. `verify_failed` намеренно не разрешен.
- `SimpleVpnController`: periodic entitlement check / `subscription_required` больше не рвет уже подключенный туннель. Состояние доступа помечается как требующее внимания, таймер entitlement check останавливается, backend получает событие `access_required_stop_suppressed`, но VPN остается подключенным.
- `VpnService`: strict connectivity commit failure больше не вызывает disconnect с `verify_failed`; вместо этого ошибка фиксируется в UI/logs, туннель сохраняется.

Проверки:

- `dart format` по измененным Dart-файлам — OK.
- `flutter analyze` по измененным Dart-файлам — OK, остались только старые warning-и в `vpn_service.dart` про неиспользуемые helper-поля/методы.
- `./gradlew :app:compileReleaseKotlin --no-daemon --stacktrace` — OK.

Важно: APK/AAB в этом шаге не собирались. Чтобы пользователи получили защиту от самопроизвольного disconnect, нужен новый билд приложения.

## 2026-06-17 — замена монохромной G-иконки для Quick Tile/шторки

- User reported that the GRANI icon in Android quick settings tile has a bad-looking lower/foot part.
- Asset usage audit:
  - active resource is `/opt/grani/mobile-app/android/app/src/main/res/drawable/ic_notification_g.xml`;
  - it is used by:
    - `QuickTileService` tile icon (`Icon.createWithResource`);
    - quick tile notice small icon;
    - VPN foreground/service notification small icon;
    - entitlement/FCM notification small icon;
    - AndroidManifest Quick Settings service icon;
    - Android default notification icon metadata;
    - Android 13+ adaptive icon monochrome layer via `mipmap-anydpi-v26/ic_launcher.xml`.
  - old bitmap files `ic_tile.png` and `ic_tile_active.png` exist but are not used by the active QuickTileService.
- User provided corrected source SVG: `icon-grani-bb.svg`.
  - Source SVG size/viewBox: `37x49`;
  - it is vertical/rectangular, black, no background.
- Replacement applied:
  - converted to Android vector in `ic_notification_g.xml`;
  - kept glyph proportions unchanged;
  - did not stretch or compress the sign;
  - used square Android vector viewport `49x49`;
  - added side padding by wrapping the original 37-wide path in `<group android:translateX="6">`, producing 6 units left and right padding;
  - kept Android display size `24dp x 24dp`;
  - changed fill to white `#FFFFFFFF` for system small-icon/tile alpha usage.
- Verification:
  - `cd /opt/grani/mobile-app/android && ./gradlew :app:processReleaseResources --no-daemon --stacktrace` succeeded;
  - no APK/AAB build was run in this pass.
- Important:
  - the fixed quick tile/notification/themed monochrome icon will appear on devices only after a new APK/AAB build and install/update.

## 2026-06-17 — обновленная квадратная G-иконка и favicon-аудит

- User provided an updated `icon-grani-bb.svg`.
  - New SVG is square: `width=48`, `height=48`, `viewBox=0 0 48 48`;
  - black path, no background.
- Android system monochrome icon updated again:
  - file: `/opt/grani/mobile-app/android/app/src/main/res/drawable/ic_notification_g.xml`;
  - now uses `viewportWidth=48`, `viewportHeight=48`;
  - no side-padding group/translate is needed anymore;
  - glyph proportions are unchanged;
  - fill is white `#FFFFFFFF` for Android small icon / quick tile / notification alpha-mask use.
- Verification:
  - `cd /opt/grani/mobile-app/android && ./gradlew :app:processReleaseResources --no-daemon --stacktrace` succeeded.
- Favicon/static asset audit:
  - public static site assets live in `/opt/grani/server-config/static-pages/`;
  - admin source assets live in `/opt/grani/admin-panel/public/`;
  - admin built assets also exist in `/opt/grani/admin-panel/build/`;
  - current favicon files:
    - `favicon.ico`;
    - `favicon.png`;
    - `favicon-32.png`;
    - `favicon-16.png`;
    - `apple-touch-icon.png`.
  - static site HTML links these in `index.html` and `privacy.html`;
  - admin public HTML links the same favicon set plus `manifest.json`.
- Note:
  - current `favicon.png` is actually `32x32`, while static HTML advertises it as `48x48`;
  - for browser favicon use, a black transparent monochrome icon can disappear on dark browser UI; better production set is: colored `favicon.ico/png` and `apple-touch-icon`, plus optional monochrome/mask SVG if needed.
- No APK/AAB build was run in this pass.

## 2026-06-17 — web favicon set: SVG/mask/PNG/ICO приведены в порядок

- User asked to apply the favicon plan using the corrected square `icon-grani-bb.svg`.
- Generated and deployed the full favicon set to all active web asset locations:
  - `/opt/grani/server-config/static-pages/`;
  - `/opt/grani/admin-panel/public/`;
  - `/opt/grani/admin-panel/build/`.
- Generated files:
  - `favicon.svg` — normal favicon SVG: white rounded square background + dark GRANI G (`#192F3F`);
  - `mask-icon.svg` — monochrome transparent SVG for mask/mono use;
  - `favicon.png` — fixed to real `48x48` PNG;
  - `favicon-32.png` — `32x32` PNG;
  - `favicon-16.png` — `16x16` PNG;
  - `apple-touch-icon.png` — `180x180` PNG;
  - `favicon.ico` — ICO generated from the same visual.
- Updated HTML favicon declarations:
  - `/opt/grani/server-config/static-pages/index.html`;
  - `/opt/grani/server-config/static-pages/privacy.html`;
  - `/opt/grani/admin-panel/public/index.html`;
  - `/opt/grani/admin-panel/build/index.html`.
- Added:
  - `<link rel="icon" href="/favicon.svg" type="image/svg+xml">`;
  - `<link rel="mask-icon" href="/mask-icon.svg" color="#192F3F">`;
  - kept PNG/ICO/apple-touch fallbacks.
- Fixed nginx static allow-list:
  - `/opt/grani/server-config/nginx/nginx.conf`;
  - added `favicon.svg` and `mask-icon.svg` to favicon static locations for root/app/admin blocks.
- Applied nginx reload:
  - `docker exec granivpn_nginx nginx -t` succeeded;
  - `docker exec granivpn_nginx nginx -s reload` completed.
  - Existing warnings remain: deprecated `listen ... http2` syntax and duplicated `admin/app` server names; not introduced by this change.
- Verification:
  - PIL checked all three asset roots:
    - `favicon.png` = `48x48`;
    - `favicon-32.png` = `32x32`;
    - `favicon-16.png` = `16x16`;
    - `apple-touch-icon.png` = `180x180`;
    - SVG/mask files exist.
  - HTML files contain `favicon.svg`, `favicon.png`, and `mask-icon`.
  - HTTP checks:
    - `https://admin.granilink.com/favicon.svg` returns `200`;
    - `https://app.granilink.com/favicon.svg` returns `200` after nginx reload;
    - `https://granilink.com/mask-icon.svg` returns `200`;
    - `https://granilink.com/favicon.svg?v=202606170717` returns `200`.
  - Note: bare `https://granilink.com/favicon.svg` returned an old Cloudflare cached `404` (`cf-cache-status: HIT`) immediately after the fix; cache-busted request confirms origin/nginx is already corrected. It should clear by Cloudflare cache expiry or manual purge.
- No APK/AAB build was run in this pass.

## 2026-06-17 — админка: страница триалов показывала не всех пользователей

- User reported that not all trials/users are visible on `https://admin.granilink.com/trials`.
- Root cause:
  - backend endpoint `/api/admin/trials` filtered the base query to users that already had trial markers:
    - `trial_active = true`;
    - or `trial_seconds_left > 0`;
    - or `trial_started_at is not null`.
  - Because of that, users that never had a trial were completely hidden, even though the page has the action to set/give a trial.
- DB check before fix:
  - total users: `59`;
  - users with `trial_started_at`: `9`;
  - users with active trial flag: `2`;
  - users with positive trial seconds: `2`.
  - This matched the UI symptom: the page showed only 9 rows.
- Backend fix:
  - file: `/opt/grani/backend/api/admin.py`;
  - `/api/admin/trials` now starts from all users, then applies optional `user_id` and email `search` filters;
  - added explicit calculated status `not_started` for users with no trial history;
  - retained statuses `active` and `expired`;
  - added support for filtering by `status=not_started`;
  - clamped `page >= 1` and `limit` to `1..500`;
  - ordering now uses `trial_started_at desc nullslast`, then `created_at desc nullslast`, then `id desc`.
- Admin frontend fix:
  - files:
    - `/opt/grani/admin-panel/src/pages/TrialsPage.tsx`;
    - `/opt/grani/admin-panel/src/services/trialsService.ts`;
  - `TrialInfo.status` now supports `active | expired | not_started`;
  - status filter dropdown now includes `Не выдавался`;
  - table chip shows `Не выдавался` for users without trial history;
  - action button says `Выдать trial` for `not_started`;
  - fixed page reset issue: `loadTrials` no longer depends on current `page`, so pagination does not immediately fall back to page 1 after clicking another page.
- Applied:
  - copied backend/admin changes to server;
  - `docker exec granivpn_api python -m py_compile /app/api/admin.py` succeeded;
  - rebuilt admin panel with `cd /opt/grani/admin-panel && npm run build`;
  - restarted `granivpn_api`.
- Verification:
  - `granivpn_api` is healthy after restart;
  - direct backend function check inside container now returns `total=59`, `20` rows on page 1;
  - `https://admin.granilink.com/trials` serves the new admin bundle `main.7339bdfa.js`.
- No APK/AAB build was run in this pass.

## 2026-06-17 — уточнение смысла статуса `Не выдавался` на странице триалов

- User asked whether users marked as `Не выдавался` actually used the service.
- Important conclusion:
  - `Не выдавался` does **not** mean "user never used GRANI";
  - it only means trial fields in `users` have no started trial timer:
    - `trial_active = false`;
    - `trial_seconds_left = 0`;
    - `trial_started_at is null`.
- DB check for users with this trial-field state:
  - total `trial_field_not_started`: `50`;
  - users with devices: `34`;
  - users with `last_login_at`: `7`;
  - users with `connection_logs`: `2`;
  - total connection log rows among them: `15`;
  - users with `device_server_peers`: `1`;
  - server peer rows among them: `13`;
  - users with `client_logs`: `1`;
  - client log rows among them: `856`;
  - telemetry rows: `0`.
- Users with real usage traces despite `trial_started_at is null` include:
  - `rail.tamaew@gmail.com` — devices, connection logs, server peers, client logs;
  - `vpn-test-bypass@grani.local` — connection logs;
  - several others have devices and/or `last_login_at`.
- Product wording note:
  - current label `Не выдавался` is potentially misleading if interpreted as "never used service";
  - more precise label would be `Триал не запускался` or `Trial не запускался`.
- No code change was made in this check.

## 2026-06-17 — mobile: описания/иконки протоколов и сохранение выбранного протокола

- User reported that the protocol selector descriptions were wrong/generic and that after returning from background/opening the app the UI kept showing WireGuard obf.
- Scope:
  - `TrialUnifiedScreen` is only a wrapper over `CleanAmneziaHomeScreen`, so one home/simple-vpn fix covers both subscription home and trial route.
- Controller fix:
  - file: `/opt/grani/mobile-app/lib/simple_vpn/simple_vpn_controller.dart`;
  - added cache key `simple_vpn_selected_protocol_id_v1`;
  - first cold/default selected protocol changed from `graniwg` to `vless_ws`;
  - `loadOptions()` now reads cached selected protocol id together with cached selected server id;
  - `_applyOptions()` now prefers the cached protocol if it is still available, otherwise falls back to the first protocol from the loaded list;
  - `selectProtocol()` persists the chosen protocol immediately;
  - successful connection also persists the actual `config.protocol` and updates `_selectedProtocol`, so future app opens show the last successfully connected protocol;
  - supported persisted ids are limited to `vless_ws`, `hysteria2`, `graniwg`.
- UI/localization fix:
  - file: `/opt/grani/mobile-app/lib/screens/main/clean_amnezia_home_screen.dart`;
  - protocol selector chip now uses a protocol-specific icon instead of always `Icons.tune`;
  - protocol bottom sheet rows use localized protocol names instead of hardcoded `protocol.label`;
  - icons:
    - `VLESS WS` -> `Icons.route_outlined`;
    - `Hysteria 2` -> `Icons.bolt_outlined`;
    - `WireGuard obf` -> `Icons.shield_outlined`.
- L10n changes:
  - files:
    - `/opt/grani/mobile-app/lib/l10n/app_ru.arb`;
    - `/opt/grani/mobile-app/lib/l10n/app_en.arb`;
    - regenerated `app_localizations*.dart`.
  - added localized protocol names:
    - `protocolNameVlessWs`;
    - `protocolNameHysteria2`;
    - `protocolNameGraniWg`.
  - updated short descriptions:
    - RU:
      - VLESS WS: `TCP/WebSocket для строгих сетей`;
      - Hysteria 2: `QUIC/UDP маршрут для нестабильной сети`;
      - WireGuard obf: `Быстрый WireGuard с маскировкой трафика`.
    - EN:
      - VLESS WS: `TCP/WebSocket path for restrictive networks`;
      - Hysteria 2: `QUIC/UDP route for unstable networks`;
      - WireGuard obf: `Fast WireGuard with traffic masking`.
- Verification:
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter gen-l10n` succeeded;
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/dart format lib/simple_vpn/simple_vpn_controller.dart lib/screens/main/clean_amnezia_home_screen.dart` succeeded;
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter analyze lib/simple_vpn/simple_vpn_controller.dart lib/screens/main/clean_amnezia_home_screen.dart --no-fatal-infos --no-fatal-warnings` succeeded with `No issues found`.
- No APK/AAB build was run in this pass.

## 2026-06-17 — mobile: корректный own-VPN статус и зачистка stale AWG notification

- User reported:
  - Android notification shade can show stale `GRANI / VPN подключён` while GRANI itself is disconnected and app shows subscription required;
  - home connect button can look connected when another app VPN is active, e.g. v2raytun.
- Root cause / risk area:
  - GRANI has two native runtime paths:
    - `SimpleAmneziaWgRunner` for `WireGuard obf` / AWG;
    - `GraniVpnService` for VLESS/HY2/Xray-like runtime.
  - `SimpleVpnController.syncNativeState()` checked only `getAmneziaWgStatus()`, so VLESS/HY2 state was not represented correctly during resume/open.
  - AWG foreground notification was stopped on the normal `SimpleAmneziaWgRunner.disconnect()` path, but could remain visible if the runner was already down/stale and the app later only observed status.
- Fixes:
  - file: `/opt/grani/mobile-app/lib/simple_vpn/simple_vpn_controller.dart`;
    - `SimpleVpnRuntime` now exposes `getNativeConnectionStatus()` in addition to `getAmneziaWgStatus()`;
    - Android and Windows runtime implementations delegate it to `NativeVpnService.getNativeConnectionStatus()`;
    - `syncNativeState()` now treats GRANI as connected only if one of our own runtime paths is active:
      - AWG: `getAmneziaWgStatus() == true`;
      - VLESS/HY2 native service: `getNativeConnectionStatus() == true`;
    - it marks disconnected only when both own runtime statuses are explicitly `false`;
    - no generic Android `TRANSPORT_VPN` signal is used for the home button state.
  - file: `/opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/GraniAwgNotificationService.kt`;
    - `stopForegroundCompat()` now also cancels AWG notification id directly;
    - companion `stop(context)` now first cancels the notification and then tries to deliver the stop intent;
    - added `cancelNotification(context)` helper.
  - file: `/opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnPlugin.kt`;
    - `getAmneziaWgStatus` now cleans stale AWG notification when the runner is not up;
    - `disconnectAmneziaWg` also performs the cleanup after runner disconnect.
- Verification:
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/dart format lib/simple_vpn/simple_vpn_controller.dart` succeeded;
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter analyze lib/simple_vpn/simple_vpn_controller.dart --no-fatal-infos --no-fatal-warnings` succeeded with `No issues found`;
  - `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin --no-daemon --stacktrace` succeeded.
- No APK/AAB build was run in this pass.

## 2026-06-17 — AmneziaWG: сверка свежего vpn:// с GRANI AWG-конфигами

- User pasted a fresh `vpn://...` key after Amnezia update and asked whether GRANI WireGuard obf configs match the updated Amnezia protocol.
- Checked latest upstream Amnezia client source from `https://github.com/amnezia-vpn/amnezia-client` on server in `/tmp/amnezia-client-latest`.
- Upstream findings from source:
  - latest AmneziaWG/AWG v2 still uses the same native config field family:
    - `Jc`, `Jmin`, `Jmax`;
    - `S1`, `S2`, `S3`, `S4`;
    - `H1`, `H2`, `H3`, `H4`;
    - optional `I1`, `I2`, `I3`, `I4`, `I5`;
    - plus normal WireGuard fields such as `PresharedKey`, `AllowedIPs`, `Endpoint`, `PersistentKeepalive`.
  - current Amnezia installer still random-generates AWG2 params with the same ranges GRANI already copied earlier:
    - `Jc` random `4..6`;
    - `Jmin=10`, `Jmax=50`;
    - `S1/S2` random `15..149` with packet-size collision checks;
    - `S3` random `0..63` with packet-size collision checks;
    - `S4` random `0..19`;
    - `H1-H4` are increasing qint32 ranges;
    - `I1` is the default DNS-shaped special junk payload, `I2-I5` are empty.
- Decoded the pasted `vpn://` enough to inspect structure, without recording private keys/secrets:
  - it is a qCompress/zlib Amnezia export-like payload;
  - decoded AWG fields include exactly the expected v2 set:
    - `Jc=5`, `Jmin=10`, `Jmax=50`;
    - `S1=138`, `S2=20`, `S3=35`, `S4=13`;
    - `H1-H4` are range strings;
    - `I1` is the default special junk payload;
    - `I2-I5` are empty;
    - native config includes `PresharedKey`.
  - The pasted text appears to have a minor copy/checksum corruption near the tail: zlib produced useful structure but ended with `incorrect data check`; enough fields were decoded to compare the AWG schema.
- Compared current GRANI DB server records without printing secrets:
  - active `SE-STO-01` currently stores legacy/older AWG params: `Jc/Jmin/Jmax/H1-H4`, missing `S1-S4/I1-I5`;
  - inactive `JP-OSA-01` stores full AWG2 enough for Amnezia v2: `Jc/Jmin/Jmax/S1-S4/H1-H4/I1`, `I2-I5` empty/missing;
  - inactive old nodes vary and are not consistently full AWG2.
- Important conclusion:
  - GRANI backend generator already knows the current AmneziaWG v2 field family and ranges;
  - but live server DB records are heterogeneous because some nodes are older/legacy and some were migrated/tested later;
  - active Sweden was **not** changed in this pass because it is the only known working production node and user previously asked not to touch it blindly.
- Backend formatting fix applied:
  - files:
    - `/opt/grani/backend/services/wireguard_manager.py`;
    - `/opt/grani/backend/infrastructure/external/wireguard_manager.py`.
  - added explicit `AWG_V2_REQUIRED_KEYS` and `AWG_V2_OPTIONAL_KEYS` constants;
  - `_format_awg_params()` now emits optional `I1-I5` lines when keys are present even if value is empty, matching Amnezia native export style (`I2 =`, `I3 =`, etc.) instead of silently dropping empty `I2-I5`.
- Verification:
  - `docker exec granivpn_api python -m py_compile /app/services/wireguard_manager.py /app/infrastructure/external/wireguard_manager.py` succeeded;
  - self-test inside container confirmed generated full AWG2 params format to 16 lines and include `I1-I5`;
  - restarted `granivpn_api`;
  - `granivpn_api` is healthy after restart.
- No APK/AAB build was run in this pass.

## 2026-06-17 — mobile: test APK 32-bit / armeabi-v7a build

- User explicitly requested: `собери 32 битную апк для теста изменений`.
- Pre-build check:
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter analyze lib/simple_vpn/simple_vpn_controller.dart lib/screens/main/clean_amnezia_home_screen.dart --no-fatal-infos --no-fatal-warnings` succeeded with `No issues found`.
- First build attempt:
  - `flutter build apk --release --target-platform android-arm` succeeded, but ABI inspection showed both `arm64-v8a` and `armeabi-v7a` because packaged native libs still included both phone ARM ABIs.
  - This intermediate artifact was not used as the final download.
- Clean 32-bit split build:
  - command:
    - `ORG_GRADLE_PROJECT_graniSplitPerAbi=true /opt/flutter/bin/flutter build apk --release --split-per-abi --target-platform android-arm`.
  - Flutter produced `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`.
  - Final APK copied to:
    - `/opt/grani/server-config/static-pages/downloads/grani-vpn-20260617-32bit-ownvpn-awg-format.apk`.
  - SHA256 file:
    - `/opt/grani/server-config/static-pages/downloads/grani-vpn-20260617-32bit-ownvpn-awg-format.apk.sha256`.
- Verification:
  - APK ABI inspection shows only `armeabi-v7a`;
  - file size: `53,116,166` bytes (`~51M` on disk);
  - SHA256: `8ea06e808aa72530434d7c77b4626e6d97d0c6cd72e98f9859be232e3802d30a`;
  - HTTP check succeeded via:
    - `https://api.granilink.com/downloads/grani-vpn-20260617-32bit-ownvpn-awg-format.apk`;
    - content type: `application/vnd.android.package-archive`;
    - content length: `53116166`.
- Project version in `pubspec.yaml` remains `1.0.4+24`; if Android refuses install over an existing build with the same version/signature state, remove the previous test APK first.

## 2026-06-17 — анализ логов 32-bit APK: VLESS/WG OK, HY2 fail до серверного handshake

- User provided phone log `логи.txt` after testing `grani-vpn-20260617-32bit-ownvpn-awg-format.apk` on 32-bit Android 11 / MIUI 12.5.7.
- Timeline correlation uses phone local time MSK = backend/node UTC+3.
- VLESS WS test:
  - backend issued `server_id=5 protocol=vless_ws` at `2026-06-17 10:34:48Z`;
  - app reported `native_start_ok` engine `xray`, endpoint `13.140.9.211:8080`;
  - Sweden node container `grani-vless-ws` showed accepted traffic from client IP `94.180.243.40`, including `mapi.speedtest.net`, Google/Facebook/Telegram endpoints;
  - node-side `websocket: close 1000 (normal)` / EOF lines are normal client-side connection closes during app/speedtest traffic, not root failure.
- Hysteria 2 test:
  - backend issued `server_id=5 protocol=hysteria2` at `2026-06-17 10:37:47Z` and stopped session `b9203ce1-9237-411f-b075-2fe93dc42a8f` as `connect_failed`;
  - phone native log generated HY2 config for `hy2-se.granilink.com:443`, auth `GRANI-SE-HY2-domain-20260611`, TLS SNI `hy2-se.granilink.com`, salamander obfs password `GRANI-SE-HY2-salamander-20260611`, MTU 1280;
  - Android logged SELinux denial for `setattr` on `/lib/arm/libhysteria2.so` because wrapper called `binary.setExecutable(true, false)` inside app native library dir;
  - HY2 process still started (`client mode`) but exited after ~6s with `FATAL failed to initialize client {"error":"connect error: timeout: no recent network activity"}`;
  - app wrapper then threw `IllegalStateException: Hysteria SOCKS port did not open`;
  - Sweden `grani-hy2-domain` docker logs had no entries for `10:37:48Z..10:38:18Z`, so this attempt did not reach a successful/loggable server-side HY2 handshake.
- WireGuard obf / AWG after HY2:
  - app connected to `13.140.9.211:51820`, Address `10.0.0.5/32`, DNS `1.1.1.1, 1.0.0.1`, MTU 1420, `Jc=4,Jmin=5,Jmax=60,H1-H4=1..4`, `PresharedKey` present;
  - phone log shows `Received handshake response` at `13:38:33.766` and again at `13:39:30.808` after restart/reopen;
  - node `wg show` confirmed peer endpoint `94.180.243.40:60283`, latest handshake, and ~37.40 MiB rx / ~29.43 MiB tx, so WG dataplane worked.
- App/minimize observation:
  - no `FATAL EXCEPTION`, `AndroidRuntime`, `SIGSEGV`, `SIGABRT`, or ANR crash was found in the attached log;
  - after first WG success at `13:38:33`, log continues with a new app PID `9692` at `13:38:39`, indicating Activity/process restart or relaunch, not tunnel failure;
  - later `DecorView visibility=4` / Firebase `Application backgrounded` after successful VLESS/WG matches app going background, possibly user/system Activity transition, not a native crash in this log.
- Real bug found and fixed:
  - `VpnPlugin.startVpnConnection()` waits up to 30s for `GraniVpnService.isVpnCommitted()` or `GraniVpnService.getLastStartError()`;
  - HY2 failure calls `handleRuntimeFailure()` then `stopSelf()`, so `GraniVpnService.instance` can disappear and the last error becomes invisible to the waiting Flutter call;
  - result: HY2 dies at ~6s, but Flutter sees generic `VPN не вышел в COMMITTED` only after ~30s.
- Code fixes applied:
  - `/opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/VpnService.kt`:
    - added companion-level `lastStartErrorSnapshot`;
    - `getLastStartError()` now returns current instance error or the last snapshot;
    - start clears the snapshot;
    - adapter/start exceptions and runtime failure record the snapshot before service teardown.
  - `/opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/Hysteria2ProcessWrapper.kt`:
    - removed `binary.setExecutable(true, false)` to avoid MIUI/SELinux `setattr` denial on packaged native library.
- Verification:
  - `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin --no-daemon --stacktrace` succeeded;
  - existing warnings only; no APK build was run in this pass.
- Remaining HY2 meaning:
  - the current fix improves failure reporting/cleanup; it does not prove HY2 network path is fixed;
  - next test should show fast HY2 failure with concrete `hysteria_process_exited:1` / `Hysteria SOCKS port did not open` instead of 30s generic timeout if the network still blocks the HY2 handshake.

## 2026-06-17 — HY2 диагностика через v2raytun: найдена причина рассинхрона GRANI vs node

- User connected manually via v2raytun with URI:
  - `hysteria2://GRANI-SE-HY2-domain-20260611@hy2-se.granilink.com:443/?sni=hy2-se.granilink.com#GRANI-SE-HY2-domain-443`
  - Important: this URI has **no salamander obfs** params.
- Sweden node observation:
  - `docker logs grani-hy2-domain` immediately showed:
    - `2026-06-17T11:05:15Z INFO client connected {"addr":"94.180.243.40:38936","id":"user","tx":0}`;
    - later TCP warnings for outbound `:7` probes/timeouts, likely client/app connectivity probes, not auth failure.
  - This proves HY2 server/container is alive and accepts the non-obfuscated domain/SNI/password profile.
- Actual server config inside container `/etc/hysteria/config.yaml`:
  - `listen: :443`;
  - ACME domain `hy2-se.granilink.com`;
  - auth password `GRANI-SE-HY2-domain-20260611`;
  - masquerade file;
  - QUIC `maxIdleTimeout: 60s`, `keepAlivePeriod: 10s`, `disablePathMTUDiscovery: true`;
  - `ignoreClientBandwidth: true`, congestion `bbr conservative`;
  - direct IPv4 outbound bound to `13.140.9.211`;
  - **no `obfs:` block**.
- GRANI backend currently issues a different HY2 client config for active Sweden (`server.id == 5`):
  - file `/opt/grani/backend/api/simple_vpn.py`, `_simple_hysteria2_profile()`;
  - `obfs_type = ... or ( salamander if server.id == 5 else ')`;
  - `obfs_password = ... or GRANI-SE-HY2-salamander-20260611`;
  - app phone log confirmed generated client YAML contained `obfs: type: salamander` + password.
- Root cause conclusion:
  - v2raytun works because it uses **non-obfuscated HY2**, matching the actual server;
  - GRANI HY2 fails because it uses **salamander-obfuscated HY2** against a server that is currently not configured for salamander;
  - this explains why GRANI attempt had no server-side HY2 logs and client timed out with `connect error: timeout: no recent network activity`.
- No changes were made in this diagnostic pass because user explicitly asked to analyze causes only.
- Practical fix options for next pass:
  1. fastest/server-only: remove forced `salamander` from GRANI backend HY2 config for Sweden and restart `granivpn_api`; no APK rebuild should be required because app consumes backend-issued config;
  2. alternative: enable matching salamander obfs on `grani-hy2-domain` server config and restart HY2 container, then test whether obfuscated HY2 still works on target networks.

## 2026-06-17 — backend HY2 Sweden: убран принудительный salamander из выдачи GRANI

- User requested the practical server-only fix after HY2 diagnostics: make GRANI issue the same Sweden Hysteria2 profile that works in v2raytun.
- Root cause from previous diagnostic:
  - Sweden HY2 container grani-hy2-domain listens on hy2-se.granilink.com:443 with password GRANI-SE-HY2-domain-20260611 and has no obfs: block in /etc/hysteria/config.yaml;
  - v2raytun works with non-obfuscated URI;
  - GRANI backend was forcing salamander for server.id == 5, so the app used a client profile that did not match the server.
- Fix applied:
  - file: /opt/grani/backend/api/simple_vpn.py;
  - _simple_hysteria2_profile() no longer defaults SIMPLE_HY2_OBFS_TYPE / SIMPLE_HY2_OBFS_PASSWORD to salamander for Sweden;
  - obfs is now emitted only if explicitly set through env vars;
  - generated revision for Sweden HY2 is now simple-vpn:5:hysteria2:hy2-se.granilink.com:443:obfs:none.
- Verification:
  - docker exec granivpn_api python -m py_compile /app/api/simple_vpn.py succeeded;
  - granivpn_api restarted and returned to healthy state;
  - direct function check inside container returned:
    - revision simple-vpn:5:hysteria2:hy2-se.granilink.com:443:obfs:none;
    - json_config.obfs_type = None;
    - sing-box outbound contains no obfs block.
- Notes:
  - no APK/AAB build was needed for this pass;
  - the current app already bypasses HY2 config cache, so a new Sweden HY2 connect should fetch the corrected backend config;
  - if the phone still keeps stale native state, fully disconnect/reconnect before retesting.
- Observed unrelated API logs after restart:
  - Paramiko warnings/errors while fetching /etc/xray/config.json from Sweden over SSH (Error reading SSH protocol banner / file not found in some attempts);
  - these are not caused by the HY2 config change but should be kept in mind for server protocol diagnostics.

## 2026-06-17 — mobile icon audit: launcher / monochrome / quick tile sizes

- User reported that the GRANI launcher icon still looks visually wrong/asymmetric on the phone home screen and asked for exact dimensions for a new clean symmetric icon.
- Current Android icon structure in /opt/grani/mobile-app/android/app/src/main/res:
  - adaptive launcher XML: mipmap-anydpi-v26/ic_launcher.xml;
  - background color: @color/ic_launcher_background = #FFFFFF;
  - adaptive foreground PNGs:
    - mdpi 108x108;
    - hdpi 162x162;
    - xhdpi 216x216;
    - xxhdpi 324x324;
    - xxxhdpi 432x432;
  - legacy launcher PNGs:
    - mdpi 48x48;
    - hdpi 72x72;
    - xhdpi 96x96;
    - xxhdpi 144x144;
    - xxxhdpi 192x192;
  - quick tile PNGs: drawable/ic_tile.png and drawable/ic_tile_active.png, both 96x96;
  - monochrome launcher/status vector referenced by adaptive icon: drawable/ic_notification_g.xml.
- Recommended new source requirements:
  - master source: square SVG or PNG, 1024x1024, sRGB;
  - launcher foreground source: transparent square, sign optically and geometrically centered on X;
  - Android adaptive safe zone: central 72dp inside 108dp; at xxxhdpi this means keep the important logo inside central 288x288 of a 432x432 foreground, or inside roughly central 683x683 of a 1024x1024 master;
  - provide/export monochrome version from the same master so quick tile/status/monochrome icon do not use a degraded separate glyph.

## 2026-06-17 — mobile icons: цветной launcher отдельно от монохромной шторки

- User clarified desired icon split:
  - keep the clean monochrome GRANI icon for notifications/status shade/quick settings tile;
  - use a colorful Google Play-style icon only for the phone launcher/app icon.
- Source image used for launcher refresh:
  - user-provided colorful GRANI icon from clipboard;
  - local generated working files stored under outputs/icon-refresh/ in the Codex workspace.
- Updated Android launcher resources on server:
  - adaptive foreground PNGs:
    - /opt/grani/mobile-app/android/app/src/main/res/drawable-mdpi/ic_launcher_foreground.png 108x108;
    - /opt/grani/mobile-app/android/app/src/main/res/drawable-hdpi/ic_launcher_foreground.png 162x162;
    - /opt/grani/mobile-app/android/app/src/main/res/drawable-xhdpi/ic_launcher_foreground.png 216x216;
    - /opt/grani/mobile-app/android/app/src/main/res/drawable-xxhdpi/ic_launcher_foreground.png 324x324;
    - /opt/grani/mobile-app/android/app/src/main/res/drawable-xxxhdpi/ic_launcher_foreground.png 432x432.
  - legacy launcher PNGs:
    - /opt/grani/mobile-app/android/app/src/main/res/mipmap-mdpi/ic_launcher.png 48x48;
    - /opt/grani/mobile-app/android/app/src/main/res/mipmap-hdpi/ic_launcher.png 72x72;
    - /opt/grani/mobile-app/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png 96x96;
    - /opt/grani/mobile-app/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png 144x144;
    - /opt/grani/mobile-app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png 192x192.
- Not changed intentionally:
  - /opt/grani/mobile-app/android/app/src/main/res/drawable/ic_notification_g.xml;
  - /opt/grani/mobile-app/android/app/src/main/res/drawable/ic_tile.png;
  - /opt/grani/mobile-app/android/app/src/main/res/drawable/ic_tile_active.png.
- Adaptive icon XML still uses:
  - background @color/ic_launcher_background (#FFFFFF);
  - foreground @drawable/ic_launcher_foreground;
  - monochrome @drawable/ic_notification_g.
- Verification:
  - server-side PNG size inspection confirmed expected Android dimensions;
  - cd /opt/grani/mobile-app/android && ./gradlew :app:mergeReleaseResources --no-daemon --stacktrace succeeded;
  - no APK/AAB build was run in this pass.

## 2026-06-17 — UpCloud PL-WAW1 test node: VLESS WS / HY2 / WireGuard obf prepared

- User created a new UpCloud test server and requested three manual test configs: VLESS, Hysteria 2, WireGuard obf.
- New node:
  - hostname: grani-pl-waw1-01;
  - public IPv4: 81.27.101.191;
  - provider/location: UpCloud PL-WAW1;
  - OS: Ubuntu Server 26.04 LTS;
  - kernel: 7.0.0-14-generic;
  - public interface: th0;
  - utility/private interface: th1, with UpCloud route 10.0.0.0/8 via utility network.
- Important networking decision:
  - did not use 10.0.0.0/24 for WireGuard/AWG because UpCloud has a broad 10.0.0.0/8 utility route;
  - test AWG subnet is 172.27.91.0/24, client 172.27.91.2/32.
- Base setup:
  - installed Docker, curl, jq, openssl, iptables, git/build tooling and kernel headers;
  - UFW active with inbound allows for 22/tcp, 8080/tcp, 443/udp, 51820/udp;
  - UFW route allow added for wg0 -> eth0.
- VLESS WS test:
  - container: grani-pl-vless-ws;
  - image: ghcr.io/xtls/xray-core:latest;
  - network mode: host;
  - config path: /opt/grani-pl-test/vless/config.json;
  - port: 8080/tcp;
  - path: /grani-ws;
  - UUID stored at /opt/grani-pl-test/vless/uuid.
- Hysteria 2 test:
  - container: grani-pl-hy2;
  - image: 	obyxdd/hysteria:latest;
  - network mode: host;
  - config path: /opt/grani-pl-test/hy2/server.yaml;
  - port: 443/udp;
  - self-signed cert CN/SNI: www.bing.com;
  - password stored at /opt/grani-pl-test/hy2/password;
  - this is an IP/self-signed test profile, not final ACME/domain production setup.
- WireGuard obf / AmneziaWG test:
  - installed kernel module from mneziawg-linux-kernel-module commit c946a9df100a17d342b5982d1947deef1b51952;
  - module verification:
    - version 1.0.0;
    - srcversion 81198FA101631BF9D6CB5CB;
    - vermagic 7.0.0-14-generic;
  - installed tools from mneziawg-tools commit 5d6179a6d0842e98dfb349c28cf1bd8e4b9d1079;
  - service: wg-quick@wg0, active/enabled;
  - server config path: /etc/amnezia/amneziawg/wg0.conf;
  - interface: wg0, address 172.27.91.1/24, listen port 51820;
  - obf params: Jc=4, Jmin=5, Jmax=60, H1=1, H2=2, H3=3, H4=4;
  - test client key material stored under /opt/grani-pl-test/awg/.
- Verification:
  - ss shows xray listening on TCP 8080, hysteria listening on UDP 443, and AWG on UDP 51820;
  - docker ps shows grani-pl-vless-ws and grani-pl-hy2 up;
  - systemctl is-active awg-quick@wg0 returns ctive;
  - wg show wg0 shows server public key, obf params, and peer 172.27.91.2/32;
  - external sanity checks from grani-do:
    - HTTP probe to http://81.27.101.191:8080/grani-ws returns expected 400 Bad Request from WS endpoint;
    - UDP probes to 81.27.101.191:443 and 81.27.101.191:51820 report reachable.
- Backend/app integration was not done in this pass; this is a manual test node/config set.

## 2026-06-17 — UpCloud PL retest analysis and fixes: VLESS OK, HY2 needs DNS, AWG upgraded to full AWG2

- User tested the first PL configs:
  - VLESS works;
  - HY2 does not;
  - WireGuard obf was displayed by clients as ordinary WireGuard and did not work as expected.
- PL node observations after test:
  - VLESS logs show real accepted traffic from user IP 94.180.243.40, including Speedtest, Google/Play, DNS and other HTTPS/UDP flows. This confirms VLESS WS on PL is functional.
  - HY2 logs show only server startup and no client connection entries. The first HY2 profile was IP/self-signed with insecure=1, not a domain/ACME profile like Sweden.
  - AWG wg0 saw the user endpoint 94.180.243.40:32875 and a latest handshake, but only tiny counters (~1.95 KiB rx / ~8.76 KiB tx). UFW routed egress/NAT existed, so this was not an obvious UFW block; the bigger issue was that the test profile was J/H-only and clients treated it like ordinary WireGuard.
- DNS check:
  - hy2-pl.granilink.com currently does not resolve;
  - therefore PL HY2 cannot yet run the same domain/ACME profile as Sweden until Cloudflare DNS gets an A record.
- HY2 domain preparation done on PL:
  - prepared /opt/grani-pl-test/hy2/server-domain.yaml based on working Sweden profile;
  - domain: hy2-pl.granilink.com;
  - auth password: GRANI-PL-HY2-domain-20260617;
  - ACME: letsencrypt, email dmin@granilink.com, http challenge ltPort: 80;
  - direct outbound binds IPv4 81.27.101.191;
  - opened 80/tcp in UFW for ACME.
  - The running grani-pl-hy2 container was not switched to this domain config yet because DNS is missing.
- Required Cloudflare DNS record before enabling domain HY2:
  - A hy2-pl.granilink.com -> 81.27.101.191;
  - Proxy status must be DNS only (grey cloud), not proxied.
- WireGuard obf/AWG fix:
  - upgraded live PL wg0 from J/H-only to full AWG2-style params:
    - Jc=5, Jmin=10, Jmax=50;
    - S1=138, S2=20, S3=35, S4=13;
    - H1=1071519248, H2=2913424241, H3=1461031527, H4=4106105820;
    - I1=0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00;
    - PresharedKey is still enabled.
  - Empty I2-I5 lines were not written to the server config because this wg parser rejects blank I2= lines.
  - /etc/amnezia/amneziawg/wg0.conf was updated and wg0 restarted with wg-quick down/up.
  - wg showconf wg0 and wg show wg0 now both show the full J/S/H/I set.
- New manual test configs to give user:
  - HY2 domain URI after DNS is created and container is switched:
    - hysteria2://GRANI-PL-HY2-domain-20260617@hy2-pl.granilink.com:443/?sni=hy2-pl.granilink.com#GRANI-PL-HY2-domain-443
  - AWG2 client config uses:
    - Address 172.27.91.2/32;
    - Endpoint 81.27.101.191:51820;
    - full J/S/H/I1 fields;
    - PresharedKey.

## 2026-06-17 — UpCloud PL HY2 domain enabled after DNS record

- User added Cloudflare DNS record: A hy2-pl.granilink.com -> 81.27.101.191, DNS only.
- Verified DNS from grani-do: hy2-pl.granilink.com resolves to 81.27.101.191.
- Switched PL Hysteria 2 container grani-pl-hy2 to domain/ACME profile using /opt/grani-pl-test/hy2/server-domain.yaml.
- Let us Encrypt ACME HTTP-01 succeeded for hy2-pl.granilink.com; container logs showed authorization finalized, validations succeeded, certificate obtained successfully, server up and running on :443.
- Certificate files exist under /opt/grani-pl-test/hy2/acme/certificates/acme-v02.api.letsencrypt.org-directory/hy2-pl.granilink.com/.
- Runtime check: docker ps shows grani-pl-hy2 up; ss shows hysteria listening on UDP *:443; xray VLESS still listens on TCP *:8080; AWG still listens on UDP 51820.
- Note: HTTP port 80 is not expected to stay open after the ACME challenge; curl to http://hy2-pl.granilink.com returned connection refused after issuance, but certificate is already obtained and HY2 uses UDP 443.
- Manual test HY2 URI: hysteria2://GRANI-PL-HY2-domain-20260617@hy2-pl.granilink.com:443/?sni=hy2-pl.granilink.com#GRANI-PL-HY2-domain-443
- No APK/AAB build was run in this pass.

## 2026-06-17 — UpCloud PL AWG retest: Amnezia works, v2rayTun likely does not implement full AWG2

- User retested the PL WireGuard obf/AWG2 config.
- Result reported by user: AmneziaVPN connects and works; v2rayTun accepts the config and shows connected, but traffic does not work.
- Node-side check after the report:
- awg show wg0 still shows full AWG2 params: Jc/Jmin/Jmax, S1-S4, H1-H4, I1 and PresharedKey.
- Latest peer endpoint was 94.180.243.40:45182 with large counters: about 37.35 MiB received and 44.82 MiB sent, consistent with the successful Amnezia test.
- awg show dump timestamp showed the latest handshake was not fresh at check time (about 5 minutes old), so v2rayTun did not appear to create a new valid AWG2 handshake on the node.
- Kernel/UFW logs did not show relevant blocks from the user IP to 51820; observed UFW blocks were unrelated internet scans/random ports.
- Current conclusion: PL AWG server config is functional with an AWG-capable client; v2rayTun can import the config but likely treats it as ordinary WireGuard or lacks compatible full AmneziaWG/AWG2 implementation, so it is not a reliable AWG test client for GRANI.

## 2026-06-17 — HY2 switched to salamander obfs for Sweden and PL

- User reported that PL HY2 still did not work, while the working target format in v2rayTun is hysteria2 URI with obfs=salamander and obfs-password.
- Node comparison showed Sweden grani-hy2-domain server YAML was still plain-domain without an obfs block, despite user testing a salamander URI. To avoid config/server mismatch, HY2 was made consistent on both server and backend.
- Sweden node updated: /opt/grani-hy2-domain/server-granilink.yaml now has top-level obfs type salamander with password GRANI-SE-HY2-salamander-20260611; container grani-hy2-domain restarted and logs show server up and running on :443.
- PL node updated: /opt/grani-pl-test/hy2/server-domain.yaml now has top-level obfs type salamander with password GRANI-PL-HY2-salamander-20260617; container grani-pl-hy2 restarted and logs show server up and running on :443.
- Backend updated: /opt/grani/backend/api/simple_vpn.py now uses _simple_hysteria2_defaults(server) with per-server HY2 domain/password/obfs defaults.
- Backend defaults now emit Sweden HY2 as hy2-se.granilink.com, password GRANI-SE-HY2-domain-20260611, obfs salamander, obfs password GRANI-SE-HY2-salamander-20260611.
- Backend defaults now emit PL HY2 as hy2-pl.granilink.com, password GRANI-PL-HY2-domain-20260617, obfs salamander, obfs password GRANI-PL-HY2-salamander-20260617.
- Direct check inside granivpn_api confirmed generated json_config has obfs_type=salamander and revisions simple-vpn:5:hysteria2:hy2-se.granilink.com:443:obfs:salamander and simple-vpn:99:hysteria2:hy2-pl.granilink.com:443:obfs:salamander.
- Mobile native Hysteria2ProcessWrapper already supported backend obfs JSON and renders native YAML as obfs.type plus obfs.salamander.password, so no APK rebuild was required for this server/backend change.
- Verification: docker exec granivpn_api python -m py_compile /app/api/simple_vpn.py succeeded; granivpn_api restarted and returned healthy; both HY2 containers restarted successfully.
- New PL manual test URI: hysteria2://GRANI-PL-HY2-domain-20260617@hy2-pl.granilink.com:443/?sni=hy2-pl.granilink.com&obfs=salamander&obfs-password=GRANI-PL-HY2-salamander-20260617#GRANI-PL-HY2-salamander-443
- New Sweden manual test URI: hysteria2://GRANI-SE-HY2-domain-20260611@hy2-se.granilink.com:443/?sni=hy2-se.granilink.com&obfs=salamander&obfs-password=GRANI-SE-HY2-salamander-20260611#GRANI-SE-HY2-salamander-443

## 2026-06-17 — PL UpCloud IP geolocation note

- User noticed Speedtest sometimes shows the new PL server as Helsinki.
- Checked 81.27.101.191 via external geo APIs from grani-do:
- ipinfo.io reports hostname 81-27-101-191.pl-waw1.upcloud.host, city Warsaw, region Mazovia, country PL, AS202053 UpCloud Ltd.
- ip-api.com reports country Poland, city Warsaw, org Upcloud PL Waw1, AS202053 UpCloud Ltd.
- Node hostnamectl confirms UpCloud VM grani-pl-waw1-01 on Ubuntu 26.04.
- Conclusion: the VPS/IP is correctly allocated to PL/Warsaw in at least two geo databases; Speedtest Helsinki is likely Ookla/server-selection/geolocation-cache/ASN-HQ mismatch, not proof that the node is physically in Helsinki.
- Operational note: for production nodes, check IP geolocation across several databases before advertising country; if Ookla/MaxMind still show the wrong city, submit a geolocation correction or ask provider for another IP/range.

## 2026-06-17 — PL-WAW1 integrated into production backend server list

- User confirmed manual tests:
- PL Hysteria 2 with salamander works in v2rayTun.
- Sweden Hysteria 2 with salamander works in GRANI.
- Integrated UpCloud Poland/Warsaw node as a production backend server record.
- New active server row:
- id: 10;
- name: PL-WAW-01;
- country/city: Польша / Варшава;
- ip_address/ssh_host: 81.27.101.191;
- provider/region: UpCloud / PL-WAW1;
- supported_protocols: [vless_ws, hysteria2, graniwg];
- graniwg_enabled: true;
- wireguard_port: 51820;
- wireguard_public_key: m4pMQ5iJQgk0D8EXNasWmSxnhrpHGIZXtTJORqBiOgA=;
- wireguard_config_path: /etc/amnezia/amneziawg/wg0.conf;
- xray_port: 8080;
- xray_config_path: /opt/grani-pl-test/vless/config.json;
- domain: hy2-pl.granilink.com;
- status/health_status: online/healthy.
- Stored server ssh_key_content from /root/.ssh/grani_nodes_ed25519 in DB for backend Paramiko provisioning; no key path is used because /root/.ssh is not mounted inside granivpn_api.
- Backend code changes:
- /opt/grani/backend/api/simple_vpn.py: _simple_xray_profile now reads per-server VLESS UUID from server_specs keys vless_ws_client_id/simple_vless_ws_client_id/xray_client_id before falling back to global default.
- /opt/grani/backend/services/wireguard_manager.py: remote GRANIwg IP allocation now passes a per-server client subnet from server_specs keys graniwg_client_network/wireguard_client_network/client_network.
- /opt/grani/backend/infrastructure/external/remote_vpn_manager.py: get_next_available_wireguard_ip now skips the first host of any configured subnet, not only hardcoded 10.0.0.1. This fixed PL allocation from returning 172.27.91.1 server address.
- PL server_specs include:
- vless_ws_client_id=7eed04f7-cf8c-49d1-b608-699e283612fb;
- h2 domain/obfs metadata for hy2-pl.granilink.com + salamander;
- graniwg_client_network=172.27.91.0/24;
- graniwg_client_mtu=1420;
- graniwg_use_preshared_key=true.
- Verification:
- py_compile passed for api/simple_vpn.py, services/wireguard_manager.py, infrastructure/external/remote_vpn_manager.py.
- granivpn_api restarted and returned healthy.
- Internal profile check for PL id=10 returned VLESS 81.27.101.191:8080 with UUID 7eed04f7-cf8c-49d1-b608-699e283612fb and path /grani-ws.
- Internal profile check returned HY2 server hy2-pl.granilink.com with obfs_type=salamander and revision simple-vpn:10:hysteria2:hy2-pl.granilink.com:443:obfs:salamander.
- GRANIwg allocator for PL now returns next_available_ip 172.27.91.3, correctly skipping server .1 and existing manual test peer .2.
- Simple server payload now has two active locations visible to the app: SE-STO-01 id=5 and PL-WAW-01 id=10, both with supported_protocols [vless_ws, hysteria2, graniwg].
- PL node runtime check: grani-pl-vless-ws and grani-pl-hy2 containers are up; ss shows TCP 8080, UDP 443, UDP 51820; awg show wg0 confirms full AWG2 params.
- No APK/AAB build was run.

## 2026-06-17 — UpCloud SG/US nodes integrated into production backend

- User bought two more UpCloud nodes and asked to integrate them into the app, using the same SSH key as PL.
- New nodes:
- SG: ubuntu-1cpu-1gb-sg-sin1, region SG-SIN1, public IPv4 213.163.206.79, Ubuntu Server 26.04 LTS, kernel 7.0.0-14-generic.
- US: ubuntu-1cpu-1gb-us-nyc1, region US-NYC1, public IPv4 85.9.193.3, Ubuntu Server 26.04 LTS, kernel 7.0.0-14-generic.
- DNS was added/fixed by user and verified from grani-do:
- hy2-sg.granilink.com -> 213.163.206.79.
- hy2-us.granilink.com -> 85.9.193.3.
- Both nodes were provisioned with the same checked AWG runtime as PL:
- copied awg, awg-quick, awg-quick@.service and amneziawg.ko from working PL node because PL/SG/US share the same Ubuntu 26.04 kernel 7.0.0-14-generic.
- Docker + UFW installed.
- UFW allows 22/tcp, 80/tcp, 8080/tcp, 443/udp, 51820/udp and wg0 -> eth0 forwarding.
- VLESS WS started on TCP 8080 with path /grani-ws.
- Hysteria 2 started on UDP 443 with Let’s Encrypt ACME and salamander obfs.
- WireGuard obf / AmneziaWG started on UDP 51820 with full AWG2 params and separate 172.27.x.0/24 client subnets, avoiding UpCloud utility 10.x routes.
- SG runtime:
- containers: grani-sg-vless-ws and grani-sg-hy2 are up.
- HY2 certificate obtained successfully for hy2-sg.granilink.com; logs show server up on :443.
- VLESS UUID: ab2dd05b-91e9-4a92-a701-75710c909bcd.
- HY2 password: GRANI-SG-HY2-domain-20260617.
- HY2 obfs: salamander, password GRANI-SG-HY2-salamander-20260617.
- AWG subnet: 172.27.92.0/24, server address 172.27.92.1/24.
- AWG public key: bJWJwSxptiJWSEybU7tlt25MgoKSr6S3eNCTpz14vmw=.
- AWG params: Jc=5,Jmin=10,Jmax=50,S1=121,S2=36,S3=9,S4=17,H1=1303710486,H2=2862076005,H3=3382519801,H4=4075881092,I1=0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00.
- US runtime:
- containers: grani-us-vless-ws and grani-us-hy2 are up.
- HY2 certificate obtained successfully for hy2-us.granilink.com; logs show server up on :443.
- VLESS UUID: 517ef9d9-5a8f-4ae2-84d5-da5c72bdd9e5.
- HY2 password: GRANI-US-HY2-domain-20260617.
- HY2 obfs: salamander, password GRANI-US-HY2-salamander-20260617.
- AWG subnet: 172.27.93.0/24, server address 172.27.93.1/24.
- AWG public key: yUstou3tEGecRs6rX8xIJHdkElgOWM+dppSIiMjwVFw=.
- AWG params: Jc=5,Jmin=10,Jmax=50,S1=117,S2=48,S3=6,S4=19,H1=1200365092,H2=2381860075,H3=3187843198,H4=3965398880,I1=0x01,0x00,0x00,0x00,0x00,0x00,0x00,0x00.
- Backend changes:
- /opt/grani/backend/api/simple_vpn.py: _simple_hysteria2_defaults(server) now reads HY2 domain/password/obfs fields from server_specs when both domain and password are present.
- The SE/PL hardcoded fallback remains. Important: this avoids breaking older PL/SE records if their server_specs contain only partial HY2 data.
- SG/US production DB records:
- SG-SIN-01: id=8, ip=213.163.206.79, country/city Сингапур/Сингапур, provider UpCloud, region SG-SIN1, active, healthy, protocols [vless_ws, hysteria2, graniwg].
- US-NYC-01: id=11, ip=85.9.193.3, country/city США/Нью-Йорк, provider UpCloud, region US-NYC1, active, healthy, protocols [vless_ws, hysteria2, graniwg].
- Both records store ssh_key_content from /root/.ssh/grani_nodes_ed25519 for backend peer provisioning.
- Both records store server_specs with VLESS UUID, HY2 domain/password/obfs, AWG subnet and graniwg_use_preshared_key=true.
- Verification:
- docker exec granivpn_api python -m py_compile /app/api/simple_vpn.py succeeded.
- granivpn_api restarted and is healthy.
- Internal backend profile check:
- SE id=5 still returns HY2 hy2-se.granilink.com with obfs salamander and password GRANI-SE-HY2-domain-20260611.
- PL id=10 still returns HY2 hy2-pl.granilink.com with obfs salamander and password GRANI-PL-HY2-domain-20260617.
- SG id=8 returns VLESS 213.163.206.79:8080 UUID ab2dd05b-91e9-4a92-a701-75710c909bcd, HY2 hy2-sg.granilink.com obfs salamander, AWG next IP 172.27.92.2.
- US id=11 returns VLESS 85.9.193.3:8080 UUID 517ef9d9-5a8f-4ae2-84d5-da5c72bdd9e5, HY2 hy2-us.granilink.com obfs salamander, AWG next IP 172.27.93.2.
- Active backend locations after integration: SE-STO-01 id=5, SG-SIN-01 id=8, PL-WAW-01 id=10, US-NYC-01 id=11.
- HTTP /api/simple-vpn/servers without user token returns UNAUTHORIZED, so endpoint payload was checked internally with the same backend code instead of unauthenticated curl.
- No APK/AAB build was run.

## 2026-06-17 — Server location localization + AWG background lifetime fix

- User reported that city names in the server selector stay Russian only, and that on a 32-bit device VPN drops when the app is closed.
- Backend location metadata was added at server-addition/production payload level:
- `/opt/grani/backend/api/simple_vpn.py` now includes `country_code`, `city_code`, `country_localized`, `city_localized` in `_simple_server_payload`.
- `_server_location_metadata(server)` reads these values from `server_specs` and has safe fallbacks for active production nodes by IP:
- SE-STO-01 13.140.9.211: `SE/STO`, `Швеция/Sweden`, `Стокгольм/Stockholm`.
- SG-SIN-01 213.163.206.79: `SG/SIN`, `Сингапур/Singapore`.
- PL-WAW-01 81.27.101.191: `PL/WAW`, `Польша/Poland`, `Варшава/Warsaw`.
- US-NYC-01 85.9.193.3: `US/NYC`, `США/United States`, `Нью-Йорк/New York`.
- Important fix: initial merge logic let old DB `server.country/city` Russian fallback overwrite English fallback; fixed so explicit `server_specs` overrides IP fallback, IP fallback overrides raw legacy `country/city`.
- Existing `server_specs` for ids 5, 8, 10, 11 were updated with localized labels using SQLAlchemy `flag_modified(server, "server_specs")`; without `flag_modified`, non-empty JSON specs for SG/PL/US did not persist nested updates reliably.
- Internal payload verification now returns correct localized values:
- SE: `Stockholm/Sweden`.
- SG: `Singapore/Singapore`.
- PL: `Warsaw/Poland`.
- US: `New York/United States`.
- Mobile app parsing/UI:
- `/opt/grani/mobile-app/lib/simple_vpn/simple_vpn_api.dart` now parses and caches `country_code`, `city_code`, `country_localized`, `city_localized`.
- `/opt/grani/mobile-app/lib/screens/main/clean_amnezia_home_screen.dart` now renders localized city/country from backend values and falls back to local dictionaries for old cached payloads.
- Existing cached app options may still show old Russian labels until options cache refreshes, re-login, or app data clear.
- Android lifecycle investigation:
- VLESS/Hysteria 2 already run via `GraniVpnService`, which is `START_STICKY` and has `onTaskRemoved` restart logic.
- WireGuard obf/AmneziaWG uses `SimpleAmneziaWgRunner` (`GoBackend`) plus `GraniAwgNotificationService` as a foreground holder, not the same `GraniVpnService` path.
- Therefore the 32-bit symptom is not expected to be caused by ABI itself; Java/Kotlin lifecycle logic is shared across 32/64-bit. The weak point was our AWG foreground holder lifecycle, especially on MIUI/OEM task removal.
- `/opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/GraniAwgNotificationService.kt` was updated:
- distinguishes explicit stop (`ACTION_STOP`) from system/task destruction;
- on `onTaskRemoved`, if `SimpleAmneziaWgRunner.isUp()` is true, keeps foreground notification and requests foreground holder restart;
- on `onDestroy`, if AWG is still UP and stop was not requested, requests holder restart instead of immediately removing foreground notification.
- This should help normal app close / swipe-away cases. It cannot protect against Android force-stop or aggressive OEM cleaner killing the whole app process; no app can keep a userspace VPN alive after a true force-stop.
- Verification:
- `docker exec granivpn_api python -m py_compile /app/api/simple_vpn.py` passed.
- `granivpn_api` is healthy after restart.
- `/opt/flutter/bin/dart format lib/simple_vpn/simple_vpn_api.dart lib/screens/main/clean_amnezia_home_screen.dart` passed.
- `/opt/flutter/bin/flutter analyze lib/simple_vpn/simple_vpn_api.dart lib/screens/main/clean_amnezia_home_screen.dart --no-fatal-infos --no-fatal-warnings` passed.
- `cd /opt/grani/mobile-app/android && ./gradlew :app:compileDebugKotlin` passed; warnings are existing dependency/deprecation warnings plus old Kotlin nullability warnings in Xray files.
- No APK/AAB build was run.

## 2026-06-17 — SG/US user test verification + AWG verify fix

- User tested Singapore and US from client side and reported that protocols work.
- Node-side check confirmed real traffic, not just open ports:
- SG `213.163.206.79`:
- VLESS WS logs show accepted traffic from user IP `94.180.243.40` to Speedtest/Google destinations; tag `vless-ws-8080 >> direct`, email `grani-sg`.
- HY2 logs show client connected from `94.180.243.40` and proxied Speedtest-like TCP targets; later stream-cancel/timeout warnings match normal client/test stream closure.
- AWG `awg show wg0 dump` shows peer public key `40VR...w2s=` on `172.27.92.2/32`, endpoint `94.180.243.40:39847`, latest handshake `2026-06-17 15:01:18 UTC`, counters about `48.3 MB rx / 50.0 MB tx`.
- US `85.9.193.3`:
- VLESS WS logs show accepted traffic from `94.180.243.40` to Speedtest targets and Speedtest API; tag `vless-ws-8080 >> direct`, email `grani-us`.
- HY2 logs show client connected from `94.180.243.40` and proxied Speedtest-like TCP targets; later stream-cancel/timeout warnings match normal client/test stream closure.
- AWG `awg show wg0 dump` shows peer public key `40VR...w2s=` on `172.27.93.2/32`, endpoint `94.180.243.40`, counters over `66 MB rx / 146 MB tx`.
- Found backend-only diagnostic bug: `/api/simple-vpn/session/verify` was calling `wg show wg0 dump`. On new UpCloud AmneziaWG nodes the correct runtime command is `awg show wg0 dump`; the tunnel worked, but backend falsely logged `peer_not_found`.
- Fixed `/opt/grani/backend/api/simple_vpn.py`: `_verify_graniwg_node_traffic()` now uses `awg show wg0 dump` when `awg` exists, falling back to `wg show wg0 dump`.
- Verification after fix:
- `docker exec granivpn_api python -m py_compile /app/api/simple_vpn.py` passed.
- `granivpn_api` restarted and is healthy.
- Internal backend verify for US id=11 now returns `verified=True`, expected allowed IP `172.27.93.2/32`, fresh handshake and non-zero traffic counters.
- Location check:
- `ipinfo` for SG `213.163.206.79` returns city/region `Singapore`, country `SG`; SG city remains `Singapore/Сингапур` because this is the actual city-state location.
- `ipinfo` for US `85.9.193.3` returns `New York City`, country `US`; DB `server_specs.city_localized.en` for US-NYC-01 updated from `New York` to `New York City`, RU remains `Нью-Йорк`.
- No APK/AAB build was run.

## 2026-06-17 — Mobile v25 release build: launcher icon + split tunnel re-enabled

- User provided final color launcher PNGs and requested release build version 25.
- Applied new color launcher icons to Android phone launcher/adaptive icon resources only:
- legacy launcher: `mipmap-mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi/ic_launcher.png` = 48/72/96/144/192.
- adaptive foreground: `drawable-mdpi/hdpi/xhdpi/xxhdpi/xxxhdpi/ic_launcher_foreground.png` = 108/162/216/324/432.
- Monochrome notification/quick tile assets were intentionally not changed:
- `drawable/ic_notification_g.xml`;
- `drawable/ic_launcher_monochrome.png`.
- Updated app version in `/opt/grani/mobile-app/pubspec.yaml` from `1.0.4+24` to `1.0.4+25`.
- Re-enabled split tunneling for WireGuard obf / GRANIwg:
- `/opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/SimpleAmneziaWgRunner.kt`: `FORCE_GRANIWG_FULL_TUNNEL=false`.
- Existing native behavior now applies `ExcludedApplications`/`IncludedApplications` and direct-domain bypass to AWG configs.
- VLESS/HY2 split tunneling paths were already active via `SplitTunnelPrefs` in native wrappers.
- Verification before build:
- `cd /opt/grani/mobile-app/android && ./gradlew :app:compileDebugKotlin` passed.
- `dart format` is not applicable to `.kt`; it was attempted and failed parse as expected, but Kotlin compile passed.
- Initial `flutter build apk --release --split-per-abi` failed because Gradle `ndk.abiFilters` conflicts with split ABI filters unless `graniSplitPerAbi` is set.
- Correct split build used `ORG_GRADLE_PROJECT_graniSplitPerAbi=true /opt/flutter/bin/flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64`.
- Release artifacts saved on server:
- `/opt/grani/outputs/releases/v25/grani-vpn-v25-arm32-release.apk` — 51 MB, ABI `armeabi-v7a`, SHA256 `d77c5ceab36809f3906b824f417f790ef672f3885630847a2ed9ee9069dd615d`.
- `/opt/grani/outputs/releases/v25/grani-vpn-v25-arm64-release.apk` — 50 MB, ABI `arm64-v8a`, SHA256 `aa175e71e562c5918101852abaeeff5271a37b76e21ff67584d99e8357d47b2b`.
- `/opt/grani/outputs/releases/v25/grani-vpn-v25-google-play-release.aab` — 147 MB, AAB ABIs `armeabi-v7a,arm64-v8a`, SHA256 `9edbdad91ba4a20d6500af895c5e3cbcc0ed82779914e453957c591fcb4418a4`.
- APK signing check:
- both APKs verify with APK Signature Scheme v2 and one signer.
- Artifacts were also copied locally to `outputs/releases/v25/` in the Codex workspace.

## 2026-06-17 — Fresh user_id=1 SG/US HY2/AWG failure check

- User asked why user 1 did not connect to Hysteria 2 / WireGuard obf on Singapore and US "now".
- Backend container `granivpn_api` is healthy.
- Backend logs for device `f53b6f1b-eb9f-4b93-975c-d6f475175065` / `user_id=1` show:
- US `server_id=11`, `protocol=graniwg` was actually alive before the fresh failed HY2 tests:
  - repeated `/session/verify` entries alternated `verified=True` and `stale_or_missing_handshake` because checks happened around the keepalive/handshake boundary;
  - real counters grew strongly, ending around `rx=77.5 MB`, `tx=778 MB`;
  - node `awg show wg0 dump` latest handshake timestamp `1781717867` = `2026-06-17 17:37:47 UTC`.
- SG `server_id=8`, `protocol=graniwg` fresh attempt:
  - app logged `connect_tap` at `17:44:22 UTC`;
  - backend issued config at `17:44:25 UTC` for peer `172.27.92.2`;
  - no normal `/session/start` followed for SG AWG;
  - client then reported `connect_failed` with `DioException [receive timeout]: Превышено время ожидания получения данных.`;
  - node `awg show wg0 dump` still showed last SG AWG handshake timestamp `1781708478` = `2026-06-17 15:01:18 UTC`, so this fresh SG AWG attempt did not reach a new handshake.
- HY2 did reach both nodes; this is not a DNS/certificate/no-listener failure:
  - US HY2 `grani-us-hy2` saw `client connected` from `94.180.243.40:52191` at `17:43:26 UTC`, then disconnected after 30s with `accepting stream failed: timeout: no recent network activity`.
  - SG HY2 `grani-sg-hy2` saw `client connected` from `94.180.243.40:35588` at `17:44:12 UTC`, then TCP attempts to Google/YouTube-like targets (`74.125.*`, `172.253.*`, `142.251.*`, `api.hy2.io`) timed out/reset and client disconnected at `17:46:32 UTC`.
- Interpretation:
  - HY2 config/server plumbing is correct enough to accept the client; failure is after tunnel establishment, in stream/data phase or client-side readiness/probe logic.
  - US AWG was not actually dead; it had real recent traffic and backend verifies.
  - SG AWG fresh attempt failed on client/control-flow side before backend session start and before node handshake. The logged symptom is app-side receive timeout, not a node-side AWG reject.
- Next useful diagnostic if this repeats: capture phone-side logs for the exact HY2/AWG attempt and add native-stage client logs around `prepareVpn/startNative/sessionStart`, because backend currently sees only final `connect_failed` for the SG AWG timeout.

## 2026-06-17 — Follow-up fresh connect check after user retried

- User retried connection and asked whether service/control operations had not completed in the failed attempt.
- Fresh US HY2 attempt completed the control chain:
  - `17:50:04 UTC` backend issued config for `user_id=1`, `server_id=11`, `protocol=hysteria2`;
  - `17:50:04 UTC` backend registered `/session/start`, session `7adf888f-5241-43f4-b3a8-2f6259fa5a10`;
  - `17:50:09 UTC` client logged `native_start_ok`, revision `simple-vpn:11:hysteria2:hy2-us.granilink.com:443:obfs:salamander`, `config_from_cache=False`;
  - `17:50:11` and `17:50:15 UTC` client logged `vpn_data_verified` / `node_data_verified`;
  - US node `grani-us-hy2` saw `client connected` from `94.180.243.40:35016` at `17:50:06 UTC`.
- Interpretation:
  - In the current US HY2 retry, service operations did complete.
  - In the previous SG AWG failure, service operations did not fully complete: config was issued, but no normal `/session/start` was recorded and the app later logged `DioException [receive timeout]`.
  - There is a naming/diagnostic weakness for HY2/VLESS: backend logs `vpn_data_verified` / `node_data_verified` even though node-side verify is currently real only for GRANIwg/AWG; for HY2/VLESS this means "native started and app-side readiness accepted", not real node traffic counters.

## 2026-06-17 — Launcher icon adaptive padding + honest HY2/VLESS diagnostics

- User reported that new launcher icons looked zoomed/cropped versus supplied assets: the letter G no longer had the expected whitespace on all four sides in Android install/account/launcher surfaces.
- Cause: Android adaptive icon uses `foreground + background`; launchers crop/scale the foreground safe zone. Putting the supplied full square bitmap directly into `ic_launcher_foreground.png` made MIUI/Google surfaces crop the outer margins, visually zooming the G.
- Fixed launcher resources on server:
  - legacy launcher icons still use user supplied bitmaps directly:
    - `mipmap-mdpi/ic_launcher.png` = `48x48`;
    - `mipmap-hdpi/ic_launcher.png` = `72x72`;
    - `mipmap-xhdpi/ic_launcher.png` = `96x96`;
    - `mipmap-xxhdpi/ic_launcher.png` = `144x144`;
    - `mipmap-xxxhdpi/ic_launcher.png` = `192x192`.
  - adaptive foreground icons were regenerated with transparent technical padding so the central safe-zone view matches the supplied full-square art:
    - `drawable-mdpi/ic_launcher_foreground.png` = `108x108`, visible art centered in `72x72`, bbox `(18,18)-(90,90)`;
    - `drawable-hdpi/ic_launcher_foreground.png` = `162x162`, visible art centered in `108x108`;
    - `drawable-xhdpi/ic_launcher_foreground.png` = `216x216`, visible art centered in `144x144`;
    - `drawable-xxhdpi/ic_launcher_foreground.png` = `324x324`, visible art centered in `216x216`;
    - `drawable-xxxhdpi/ic_launcher_foreground.png` = `432x432`, visible art centered in `288x288`, bbox `(72,72)-(360,360)`.
- Notification/quick tile monochrome icons were not changed.
- Diagnostic logging fixed:
  - `/opt/grani/mobile-app/lib/simple_vpn/simple_vpn_controller.dart` now logs `node_data_verified` / `vpn_data_verified` only for protocols with real server-side node counters: `graniwg`, `amneziawg`, `awg`.
  - HY2/VLESS now log `client_runtime_verified` / `client_runtime_unverified` with `verification_scope=client_runtime`, avoiding the misleading impression that backend verified node counters.
  - `/opt/grani/backend/api/simple_vpn.py` maps new events:
    - `client_runtime_verified -> connection_success`;
    - `client_runtime_unverified -> connection_error`;
    - `node_data_verified -> traffic_first_seen`;
    - `node_data_unverified -> connection_error`.
- Verification:
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/dart format lib/simple_vpn/simple_vpn_controller.dart` passed.
  - `cd /opt/grani/mobile-app && /opt/flutter/bin/flutter analyze lib/simple_vpn/simple_vpn_controller.dart --no-fatal-infos --no-fatal-warnings` passed.
  - `docker exec granivpn_api python -m py_compile /app/api/simple_vpn.py` passed.
  - `granivpn_api` restarted and is healthy.
- No APK/AAB build was run after this change.
## 2026-06-17 — AWG background status: notification + Quick Tile reconciliation

User test: after closing the app, the VPN tunnel itself did not drop, which is correct, but the GRANI foreground notification disappeared and the Quick Settings tile showed disconnected. This means the Android VPN dataplane stayed alive while our UI/native status wrapper lost the foreground/tile state.

Fix implemented in Android native code:

- Added `/opt/grani/mobile-app/android/app/src/main/kotlin/com/granivpn/mobile/NativeVpnRuntimeState.kt`.
- New native source of truth for AWG background state:
  - `SimpleAmneziaWgRunner.isUp()`;
  - persisted `amneziawg_expected_up=true`;
  - Android `ConnectivityManager` has an active `TRANSPORT_VPN` network;
  - last cached protocol is `graniwg`.
- `SimpleAmneziaWgRunner`:
  - marks `amneziawg_expected_up=true` only after AWG reaches `Tunnel.State.UP`;
  - marks it false on disconnect/non-UP result;
  - notifies Quick Tile after start/stop;
  - `disconnect(context)` can recreate `GoBackend` from context, so Quick Tile can try to stop AWG even after process recreation when the old backend object is gone.
- `QuickTileService`:
  - now displays active state from `NativeVpnRuntimeState.isAnyGraniVpnLikelyActive()`, not only in-memory `SimpleAmneziaWgRunner.isUp()`;
  - if it sees running AWG, it asks the notification holder to reconcile/restart;
  - disconnect from tile now uses `SimpleAmneziaWgRunner.disconnect(applicationContext)`.
- `GraniAwgNotificationService`:
  - start is ignored if AWG is neither active nor expected;
  - on `onTaskRemoved` / `onDestroy`, if AWG is still likely active, it keeps/restarts foreground notification and refreshes Quick Tile instead of removing notification;
  - explicit `ACTION_STOP` clears expected state and removes notification.
- `VpnPlugin.getAmneziaWgStatus`:
  - now reports connected from the same likely-active logic and reconciles notification if needed;
  - no longer treats a lost in-memory runner as disconnected while Android still has the VPN network up.

Verification:

- `cd /opt/grani/mobile-app/android && ./gradlew :app:compileDebugKotlin --no-daemon --stacktrace` passed.
- Warnings are non-blocking existing Kotlin/Android deprecation/nullability warnings plus `ConnectivityManager.allNetworks` deprecation in the new helper.

Expected phone test:

1. Connect using GRANIwg / WireGuard obf.
2. Close/swipe the app away.
3. VPN must stay up.
4. GRANI foreground notification must remain or be restored.
5. Quick Settings tile must show active/connected.
6. Tapping the tile while the app is closed should still attempt to disconnect AWG.

No APK/AAB build was run in this step.
## 2026-06-17 — Mobile v26 release build: AWG notification/tile fix

User asked to build version 26 APK and AAB after the AWG background status fix.

Version:

- `/opt/grani/mobile-app/pubspec.yaml` updated from `1.0.4+25` to `1.0.4+26`.

Build commands:

```bash
cd /opt/grani/mobile-app
ORG_GRADLE_PROJECT_graniSplitPerAbi=true /opt/flutter/bin/flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64 --split-debug-info=build/symbols/release-26
/opt/flutter/bin/flutter build appbundle --release --target-platform android-arm64 --android-project-arg=graniAbiFilters=arm64-v8a --android-project-arg=graniExcludeArmv7=true --split-debug-info=build/symbols/release-26-arm64-play
```

Release artifacts on server:

- `/opt/grani/outputs/releases/v26/grani-vpn-v26-arm32-release.apk`
  - 52,539,526 bytes / about 51 MB
  - SHA256 `727f7fbfc7012b5851213b822b8b4cab0a817023361e06ea744071a35d0c63dc`
- `/opt/grani/outputs/releases/v26/grani-vpn-v26-arm64-release.apk`
  - 51,217,082 bytes / about 49 MB
  - SHA256 `526360bd49828f548e1e20388ea1edd0167a630d17655e8e254410159557299e`
- `/opt/grani/outputs/releases/v26/grani-vpn-v26-google-play-arm64-release.aab`
  - 83,819,398 bytes / about 80 MB
  - SHA256 `812e7c0a0f7670ac15132ffc691f350a9fdcd9867e140cd843562775ac0fd481`

Local copies:

- `outputs/releases/v26/grani-vpn-v26-arm32-release.apk`
- `outputs/releases/v26/grani-vpn-v26-arm64-release.apk`
- `outputs/releases/v26/grani-vpn-v26-google-play-arm64-release.aab`

Verification:

- Both APKs verify with APK Signature Scheme v2 and one signer.
- Google Play AAB contains `base/lib/arm64-v8a`.
- Google Play AAB does not contain `base/lib/armeabi-v7a`.
- Local SHA256 hashes match server hashes.


## 2026-06-18 — Morning status audit after overnight work

- Current server time during audit: `2026-06-18 07:31 UTC`.
- Main containers are up:
  - `granivpn_api` healthy, up ~13h;
  - `granivpn_admin`, `granivpn_nginx`, `granivpn_flower`, `granivpn_beat`, `granivpn_celery`, `granivpn_postgres`, `granivpn_redis` are running.
- Overnight/mobile context additions found:
  - AWG background status fix was implemented in native Android code:
    - new `NativeVpnRuntimeState.kt`;
    - Quick Tile/foreground notification now reconcile from likely-active AWG state instead of only in-memory runner;
    - `VpnPlugin.getAmneziaWgStatus` also uses the likely-active state.
  - Version bumped to `1.0.4+26`.
  - v26 release artifacts exist:
    - `/opt/grani/outputs/releases/v26/grani-vpn-v26-arm32-release.apk` SHA256 `727f7fbfc7012b5851213b822b8b4cab0a817023361e06ea744071a35d0c63dc`;
    - `/opt/grani/outputs/releases/v26/grani-vpn-v26-arm64-release.apk` SHA256 `526360bd49828f548e1e20388ea1edd0167a630d17655e8e254410159557299e`;
    - `/opt/grani/outputs/releases/v26/grani-vpn-v26-google-play-arm64-release.aab` SHA256 `812e7c0a0f7670ac15132ffc691f350a9fdcd9867e140cd843562775ac0fd481`.
- Working node status:
  - Sweden `13.140.9.211`: HY2 domain container up ~18h; VLESS test containers up; AWG shows recent traffic for peer `40VR...`.
  - Poland `81.27.101.191`: HY2 up ~18h; VLESS up ~19h; AWG peer `40VR...` has traffic.
  - Singapore `213.163.206.79`: HY2/VLESS up ~17h; AWG peer `40VR...` has traffic.
  - US `85.9.193.3`: HY2/VLESS up ~17h; AWG peer `40VR...` has traffic.
- Morning backend log observations:
  - There were a few initial `401 invalid token` responses around `2026-06-18 06:47 UTC`, then the same requests succeeded; likely token refresh/startup race, not persistent outage.
  - User `1` started VLESS WS sessions against US `server_id=11` and Poland `server_id=10`.
  - New diagnostic naming is active: VLESS now logs `client_runtime_verified` with `verification_scope=client_runtime`, instead of pretending to have server-side node counters.
  - One VLESS verify attempt logged `node_data_verify_failed` with a Dio receive timeout, then later `client_runtime_verified` succeeded for the same PL session. This suggests transient control/request timeout rather than a hard backend outage.
- No new APK/AAB build was performed during this audit.
## 2026-06-18 — сбор и анализ: самопроизвольные отключения, уведомления подписки, этапы connect

Режим работы: только сбор и анализ, без правок кода и без сборки.

### Пользователь 1 / подписка / устройство

- Активная подписка у user_id=1 есть: subscription id=41, status=active, source=manual, end_date=2026-06-28 09:36:00 UTC (12:36 MSK), auto_renew=false.
- Рядом есть старая expired-подписка id=40 с тем же end_date. Это может путать UI/локальный кеш, если где-то берется не последняя active-запись, а первая/старая запись истории.
- Активные события 2026-06-18 идут с устройства Xiaomi M2006C3LG, device_id=f53b6f1b-eb9f-4b93-975c-d6f475175065. В БД оно is_enabled=true, но is_active=false и is_vpn_enabled=false. Это важный подозреваемый для странностей с доступом, повторной регистрацией и экраном оплаты.

### Уведомления об окончании подписки

- По backend/celery за 2026-06-18 не найдено отправки expiry/trial уведомлений пользователю:
  - vpn.check_subscription_expiry каждый час: expired=0, emails_sent=0.
  - notifications.check_trial_expiry: deactivated=0, notifications_sent=0.
  - notifications.send_subscription_expiry_warning в 09:00 UTC / 12:00 MSK: sent=0, errors=0.
- В client_logs за день нет событий subscription/access/paywall/entitlement для user_id=1.
- Вывод: частые уведомления "подписка заканчивается" не подтверждаются серверной отправкой за сегодня. Возможные источники: старые локальные уведомления/журнал на телефоне, локальный foreground-баннер от уже полученного FCM, либо клиентский переход по accessRequired, не отраженный как subscription event в client_logs.

### Отключения VPN

- Два важных эпизода выглядят как управляемый stopVpn на нативном уровне, а не как внезапная потеря туннеля сетью:
  - 10:15 MSK: перед переключением/подключением vless_ws server_id=10 остановлен предыдущий graniwg server_id=11. В логах: native_tun_state=core_stopped, native_tun2socks_kill_request reason=confirmed_stop, source=stopVpn, затем closed/cleanup.
  - 14:48 MSK: vless_ws server_id=10 был поднят из кеша, через ~40 секунд снова пришла такая же цепочка stopVpn: core_stopped -> confirmed_stop -> closed -> cleanup. После этого сразу новый vless_ws start из кеша.
- В текущих логах нативный слой пишет только source=stopVpn / confirmed_stop. Высокоуровневая причина Dart-слоя (user, subscription, protocol_switch, quick_tile, lifecycle и т.д.) не попадает в native_runtime_diag, поэтому точно назвать инициатор 14:48 MSK по серверным данным нельзя.
- Backend событие VPN_TUNNEL_CLOSED найдено в 14:38:54 MSK для graniwg server_id=10, attrs force=false. Оно не похоже на массовую серверную принудительную остановку подписки.

### Экран оплаты на доли секунды

- В SimpleVpnController _handleAccessRequired выставляет accessRequired=true на 402 от simple-vpn/config/start/verify/loadOptions.
- CleanAmneziaHomeScreen при _controller.accessRequired автоматически делает Navigator.pushNamed('/subscription', SubscriptionScreenMode.expired).
- Если затем auth refresh видит активную подписку, экран может быстро вернуться на home. Это объясняет наблюдение "на доли секунды страница оплаты тарифа, потом home", даже если реальная подписка активна.
- Для уже connected-состояния access_required сейчас не должен рвать туннель: есть policy keep_tunnel_until_explicit_stop и событие access_required_stop_suppressed. Но если accessRequired приходит во время connecting/disconnected, код все еще может вызвать native disconnect reason=access_expired.

### 4 этапа / блоки прогресса подключения

Текущая UI-ветка показывает линейный прогресс, но логика процентов осталась такой:

1. 0-25%: локальная подготовка и право на VPN — requestPermission, загрузка серверов/протоколов при пустом кеше, ensureDeviceRegistered, connect_tap.
2. 25-55%: профиль и control-plane — чтение кеша конфига или GET /simple-vpn/config, запись кеша, POST /simple-vpn/session/start. Основной затык на "2 блоке" означает, что задержка чаще всего в config/profile/session-start/device/auth, а не в самом нативном туннеле.
3. 55-80%: нативный запуск — preconnect disconnect(before_connect), создание TUN/tun2socks/xray/hysteria/amneziawg runtime.
4. 80-100%: проверка трафика и фиксация connected — native_start_ok, client_runtime/server_node verify, traffic_first_seen.

### Кеш / повторное подключение

- Для vless_ws кеш реально работает: много запусков server_id=10 идут с config_from_cache=true и native_start_ok обычно через 2-3 секунды.
- Для hysteria2 кеш сейчас принудительно выключен кодом: selectedProtocolId == 'hysteria2' -> _removeCachedConfig перед connect. Поэтому Hysteria всегда ощущается как первичная подготовка, даже после исправления серверного конфига.
- Connect всегда вызывает ensureDeviceRegistered до чтения конфига из кеша. На мобильной сети это может выглядеть как "полная регистрация" при каждом повторном подключении, особенно если токен протух/обновляется или устройство в БД is_active=false.

### Что занимало время сегодня

- Backend API обычно отвечает быстро: /simple-vpn/config, /session/start, /session/verify, /auth/me, device endpoints чаще 10-20 мс.
- Реальные задержки/неровности видны на клиентской стороне:
  - token refresh / 401 -> повтор через ~1-2 секунды, особенно около 16:21 UTC при запуске Hysteria.
  - node_data_verify_failed receive timeout на мобильной сети: например около 14:28 MSK было две попытки с Dio receive timeout перед последующими verify.
  - Hysteria без кеша добавляет обязательный config fetch и полный старт.
- Проблемы сильнее на мобильном интернете из-за receiveTimeout/переключений сети и более медленного первого запроса к control-plane.

### Предварительные направления оптимизации (без внедрения)

- Логировать в native_runtime_diag высокий source/reason из Dart при stopVpn, чтобы отличать user stop, protocol switch, quick tile, subscription, lifecycle, preconnect.
- Не отправлять connected-туннель в stop при transient access/401/402; для connecting/disconnected отдельно проверить, не превращается ли краткий 402/устаревший токен в disconnect/accessRequired.
- Проверить и выровнять статус устройства 257: почему активное Xiaomi в БД is_active=false.
- Для Hysteria вернуть кеш после стабилизации конфигов: убрать unconditional bypassConfigCache или ввести revision-aware invalidation.
- Уменьшить ощущение "полной регистрации": не дергать ensureDeviceRegistered на каждом warm reconnect, если device_id уже есть и недавно подтвержден, либо делать lazy/background refresh после старта.
- Пересмотреть node traffic verification для non-graniwg: не блокировать UX, сократить/отложить retries, логировать как analytics-only.
## 2026-06-18 — фикс рассинхрона Android VPN / Quick Tile / UI error

Повод: пользователь прислал два скрина:

- Скрин 1: в шторке одновременно есть штатное foreground-уведомление GRANI `VPN connected` и второе уведомление GRANI `Connect in the app first`; после появления второго уведомления VPN отключается.
- Скрин 2: в статус-баре Android виден VPN-значок, но приложение показывает `Connection failed / Retry`.

Вывод по коду:

- `Connect in the app first` создается не VPN-сервисом, а `QuickTileService.showQuickTileNotice()` при `lastConfig == null`.
- До фикса устойчивое "expected up" состояние было только для AmneziaWG (`amneziawg_expected_up`). Для VLESS WS / Xray / Hysteria2 после пересоздания процесса Flutter/статических полей Android мог продолжать держать VPN/TUN, но приложение и Quick Tile уже не узнавали его как наш активный туннель.
- `getStatus` для Flutter опирался только на `GraniVpnService.isVpnCommitted()`. Это создавало ложный UI error, если Android VPN уже активен (`TRANSPORT_VPN` / foreground service), а нативный `COMMITTED` еще не восстановился или был потерян после пересоздания процесса.
- В `QuickTileToggleActivity` при отсутствии кешированного конфига не было guard-а "если VPN уже активен, ничего не стартовать и не показывать no_config".

Что изменено:

- `NativeVpnRuntimeState.kt`
  - Добавлены generic-флаги для нативных протоколов: `native_vpn_expected_up`, timestamp и protocol.
  - Добавлен `isNativeVpnLikelyActive()`: true, если `GraniVpnService.isVpnRunning()` или если сохранено expected-up для non-AWG протокола и Android показывает `TRANSPORT_VPN`.
  - `isAnyGraniVpnLikelyActive()` теперь учитывает VLESS/Xray/Hysteria2, а не только AWG.

- `VpnService.kt`
  - После успешного локального старта Xray/VLESS (`LOCAL_UP`) сервис помечает `NativeVpnRuntimeState.markNativeVpnExpectedUp(true, protocol)`.
  - После успешного локального старта Hysteria2 (`LOCAL_UP`) делает то же самое.
  - При штатном `stopVpn()` expected-up сбрасывается в false.

- `VpnPlugin.kt`
  - `getStatus` теперь возвращает connected=true по `NativeVpnRuntimeState.isAnyGraniVpnLikelyActive()`, а не только по `COMMITTED`.
  - `startVpnConnection` больше не ждет только `COMMITTED`: если нативный туннель уже дошел до `LOCAL_UP` / likely-active, метод возвращает success и сохраняет lastConfig. Полная проверка трафика остается в Dart как non-blocking verify.

- `QuickTileToggleActivity.kt`
  - Перед чтением `lastConfig` добавлен guard: если любой GRANI VPN уже likely-active, Activity просто обновляет Quick Tile и закрывается. Это должно убрать сценарий, где активный VPN получает `Connect in the app first`, открывает main в quick-toggle режиме и провоцирует повторный start/stop.

Проверка:

- Выполнено на сервере: `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin`.
- Результат: `BUILD SUCCESSFUL in 2m 15s`.
- Были только существующие warnings по deprecated `Notification.Builder`, deprecated `ConnectivityManager.allNetworks` и Java type mismatch warnings в Xray parser/native wrapper; ошибок от нового патча нет.

Что проверить на телефоне:

- Подключить VLESS WS, закрыть приложение, открыть шторку: должно остаться одно корректное foreground-уведомление GRANI `VPN connected`; Quick Tile не должна показывать `Connect in the app first`, если VPN уже активен.
- Открыть приложение при активном системном VPN: UI должен восстановиться в connected, а не показывать `Connection failed / Retry`.
- Нажатие Quick Tile при активном туннеле отдельно перепроверить: теперь плитка должна видеть active state для VLESS/Hysteria2, но сценарий отключения после потери process-state нужно смотреть по logcat, если повторится.
### Дополнение к фиксу Quick Tile

После основного фикса добавлено еще одно уточнение в `QuickTileService.kt`:

- Если Quick Tile видит active-state для VLESS/Xray/Hysteria2 через новый `NativeVpnRuntimeState.isNativeVpnLikelyActive()`, клик по плитке теперь отправляет штатный `GraniVpnService.stopService(source=quick_tile, reason=user)`.
- Это нужно, чтобы плитка не только правильно отображала активный туннель после потери process/static-state, но и могла штатно отключить его по инициативе пользователя.

Повторная проверка:

- `cd /opt/grani/mobile-app/android && ./gradlew :app:compileReleaseKotlin`
- Результат: `BUILD SUCCESSFUL in 1m 2s`.
## 2026-06-18 — собрана 32-bit APK v26 с quicktile/native-state fix

Запрос: собрать 32-битную APK для теста на телефоне.

Версия:

- `pubspec.yaml`: `1.0.4+26`.
- Перед сборкой выполнено `scripts/sync_versions.sh`, без увеличения версии.
- `CODE_VERSION` в `VpnService.kt`: `2026-06-18-v26-0758017`.

Команда сборки:

```bash
cd /opt/grani/mobile-app
ORG_GRADLE_PROJECT_graniSplitPerAbi=true /opt/flutter/bin/flutter build apk \
  --release \
  --split-per-abi \
  --target-platform android-arm \
  --no-tree-shake-icons \
  --split-debug-info=build/symbols/release-26
```

Результат Flutter:

- `/opt/grani/mobile-app/build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk`
- size: `53.1MB` по Flutter / `53,092,674` bytes по HTTP.
- SHA256: `2e38d8c21718ee37353f4718be1269d27a49d3b20e8afb3850c78d76b158032c`.
- ABI inspection: только `armeabi-v7a`.
- `apksigner verify --verbose`: `Verifies`, v2 signature true.
- `classes.dex` содержит `2026-06-18-v26-0758017`.

Сохраненные артефакты:

- `/opt/grani/outputs/releases/v26/grani-vpn-v26-arm32-quicktile-statefix-release.apk`
- `/opt/grani/outputs/releases/v26/grani-vpn-v26-arm32-quicktile-statefix-release.apk.sha256`

Публичная ссылка:

- `https://api.granilink.com/downloads/grani-vpn-v26-arm32-quicktile-statefix.apk`
- SHA256: `https://api.granilink.com/downloads/grani-vpn-v26-arm32-quicktile-statefix.apk.sha256`

Проверка публичной ссылки:

- HTTP/2 `200`.
- `content-type: application/vnd.android.package-archive`.
- `content-length: 53092674`.
- `content-disposition: attachment`.
- `cf-cache-status: BYPASS`.

Эта сборка содержит сегодняшний fix рассинхрона Android VPN / Quick Tile / UI error:

- expected-up state для VLESS/Xray/Hysteria2;
- `getStatus` через `NativeVpnRuntimeState.isAnyGraniVpnLikelyActive`;
- guard от ложного `Connect in the app first` при активном VPN;
- Quick Tile disconnect для native likely-active VLESS/Hysteria2 через `source=quick_tile`, `reason=user`.
## 2026-06-18 — GitHub, AmneziaWG fork, Windows platform start

Контекст: начинаем полноценную разработку Windows-платформы GrANI. AWS account закрыт, потому для Windows-сборок выбран GitHub + GitHub Actions, а не Windows VPS.

GitHub:

- Основной приватный репозиторий: `https://github.com/railtamaew/grani`.
- SSH-доступ с сервера `/opt/grani` настроен через ключ `/opt/grani/.ssh/grani_vpn_key`.
- Remote `/opt/grani`: `git@github.com:railtamaew/grani.git`.
- Основная ветка: `main`.
- Старую локальную серверную git-историю не пушили, чтобы не тащить секреты.
- Push protection GitHub поймал Figma PAT; реальные `figd_...` токены удалены из docs, `docs/figma_auth_data.json` исключен из git.
- Live `server-config/docker/docker-compose.yml` исключен через `.gitignore`, потому содержит production secrets.

AmneziaWG submodule:

- Создан fork: `https://github.com/railtamaew/amneziawg-android`.
- Ветка с нашими патчами: `grani-patches`.
- Commit патчей: `16faa50 Apply GrANI Android AmneziaWG patches`.
- В основном GrANI submodule теперь указывает на `https://github.com/railtamaew/amneziawg-android.git`, branch `grani-patches`.
- GrANI commit: `84bc3cf Track GrANI AmneziaWG fork`.
- Патчи внутри AmneziaWG нужны Android-сборке: package name, Gradle/NDK fixes, 16KB page size, default `h1..h4` для AWG obfuscation, diagnostic config logs.

Windows platform:

- Workflow `.github/workflows/desktop-build.yml` существует и собирает Windows/macOS через Flutter 3.24.x.
- Windows native channel уже есть: `mobile-app/windows/runner/grani_vpn_channel.cpp`.
- Channel `com.granivpn.mobile/vpn` поддерживает `connectAmneziaWg`, `disconnectAmneziaWg`, `getStatus`, `getTrafficStats`, `requestPermission`.
- Windows native code ищет runner так:
  1. env `GRANI_AWG_QUICK`;
  2. bundled asset `data/flutter_assets/bin/amneziawg/windows/awg-quick.exe`;
  3. рядом с exe: `awg-quick.exe`.
- На 2026-06-18 в `mobile-app/bin/amneziawg/` есть только `README.md`; реального `windows/awg-quick.exe` пока нет.
- Поэтому текущий Windows build может собрать UI/exe, но реальное подключение вернет `WINDOWS_AWG_RUNNER_MISSING`, пока runner не будет добавлен или задан через `GRANI_AWG_QUICK`.

Сделанная правка Windows path:

- Файл: `mobile-app/lib/services/vpn_service.dart`.
- Commit: `ed414cf Enable Windows GraniWG connect path`.
- `_applyGraniWGConfig` теперь вызывает `NativeVpnService.connectAmneziaWg` не только на Android, но и на Windows.
- `_disconnectGraniWG` теперь вызывает `NativeVpnService.disconnectAmneziaWg` на Android и Windows.
- Для Windows source label: `desktop_windows_amneziawg`.
- `flutter analyze lib/services/vpn_service.dart` прошел без errors; остались старые warnings: unused fields/helpers в `vpn_service.dart`.

Следующий шаг:

1. Проверить GitHub Actions `Desktop Build` после commit `ed414cf`.
2. Если Windows build проходит, скачать `windows-release` artifact.
3. Решить доставку Windows runner:
   - временно для теста через env `GRANI_AWG_QUICK`;
   - затем добавить/bundle `bin/amneziawg/windows/awg-quick.exe` или другой корректный Windows AmneziaWG runner.
4. После runner-теста запускать exe от администратора на Windows и проверять реальный tunnel up/down.

### 2026-06-18 — Windows runner follow-up

После записи основного Windows-контекста проверены upstream репозитории Amnezia:

- `https://github.com/amnezia-vpn/amneziawg-go` в README говорит, что Windows usage должен идти через `amneziawg-windows`.
- `https://github.com/amnezia-vpn/amneziawg-windows` в README описывает сборку `x64/tunnel.dll` через `build.cmd`.
- Вывод: текущий contract в `mobile-app/windows/runner/grani_vpn_channel.cpp` с поиском `awg-quick.exe` полезен как временный MVP/debug runner contract, но не совпадает напрямую с official Amnezia Windows integration.
- Следующий engineering decision: либо создать совместимый `awg-quick.exe` wrapper вокруг `amneziawg-windows/tunnel.dll`, либо переписать Windows native channel на прямую интеграцию с `tunnel.dll`/service model.
2026-06-18 Windows platform update: native AmneziaWG service runner

- Goal: continue full Windows platform development for GrANI without AWS Windows VPS; use private GitHub repo + GitHub Actions Windows runner for builds.
- Previous Windows runner was only an MVP looking for `awg-quick.exe`. Upstream check showed this is not the official AmneziaWG Windows path: `amneziawg-go` points Windows users to `amneziawg-windows`, which builds `x64/tunnel.dll`.
- Implemented Windows service-host path:
  - `mobile-app/windows/runner/main.cpp` now detects `/awg-service <config_path> <tunnel_name>` before Flutter startup.
  - In service mode it reads UTF-8 config, resolves `tunnel.dll` from `GRANI_AWG_TUNNEL_DLL`, bundled `data/flutter_assets/bin/amneziawg/windows/tunnel.dll`, or app dir `tunnel.dll`, then calls exported `WireGuardTunnelService(configWide, tunnelNameWide)`.
  - `mobile-app/windows/runner/grani_vpn_channel.cpp` now prefers `tunnel.dll`: writes config to `%LOCALAPPDATA%\GRANI\grani-awg.conf`, stops old service, creates/updates Windows service `grani-awg`, sets dependencies `Nsi` and `TcpIp`, sets unrestricted service SID, starts service, and waits for `SERVICE_RUNNING`.
  - `awg-quick.exe` fallback remains only for legacy/debug testing via `GRANI_AWG_QUICK` or bundled/local `awg-quick.exe`.
  - Native status now reports runner `tunnel.dll`, `awg-quick`, or `missing`, and checks the Windows service state when possible.
- Updated `mobile-app/bin/amneziawg/README.md`: Windows production binary is now `windows/tunnel.dll` from `https://github.com/amnezia-vpn/amneziawg-windows`; macOS remains `amneziawg-go`.
- Updated Dart comment in `mobile-app/lib/services/vpn_service.dart` to reflect the Windows `tunnel.dll` service path.
- Verification:
  - `git diff --check` passed.
  - `flutter analyze lib/services/vpn_service.dart` ran; no new Dart errors, only the known six warnings about unused fields/methods in `vpn_service.dart`.
  - Windows compile/runtime still must be validated by GitHub Actions on Windows and then on a real Windows machine with built `tunnel.dll` bundled or `GRANI_AWG_TUNNEL_DLL` set.
- Next required task: build or fetch `amneziawg-windows` `x64/tunnel.dll`, add it to `mobile-app/bin/amneziawg/windows/tunnel.dll` or configure CI to build/package it, then run GitHub Actions Windows desktop build and test connect as admin.
2026-06-18 Windows CI update: build tunnel.dll in GitHub Actions

- Added `.github/workflows/desktop-build.yml` Windows job step before `flutter build windows --release`.
- The step clones `https://github.com/amnezia-vpn/amneziawg-windows`, runs `cmd /c build.cmd` on the GitHub Windows runner, and copies `x64/tunnel.dll` into `mobile-app/bin/amneziawg/windows/tunnel.dll`.
- This avoids committing the binary DLL to the private repo while still bundling it into Flutter assets for the Windows release artifact.
- Important: the first CI run may take longer because `build.cmd` downloads Go, llvm-mingw, and Wintun into its `.deps` folder.
- Next validation point: confirm the GitHub Actions Windows job completes and that the uploaded `windows-release` artifact contains `data/flutter_assets/bin/amneziawg/windows/tunnel.dll`.
2026-06-18 GitHub Actions fix: Flutter SDK version

- GitHub Actions Desktop Build failed on both Windows and macOS during `Install dependencies` / `flutter pub get`.
- Root cause from Actions logs: workflow used Flutter `3.24.x`; that SDK pins `flutter_localizations -> intl 0.19.0`, while `mobile-app/pubspec.yaml` requires `intl ^0.20.2`, so version solving failed before any Windows or macOS build step.
- Server/local project is on Flutter `3.38.3` stable, Dart `3.10.1`; dependencies resolve there.
- Updated `.github/workflows/desktop-build.yml` and `.github/workflows/mobile-app.yml` from Flutter `3.24.x` to `3.38.3`.
- Also hardened `mobile-app/windows/runner/main.cpp`: service-mode config file reading now uses WinAPI `CreateFileW`/`ReadFile` instead of `std::ifstream(std::wstring)`, avoiding MSVC wide-path/STL compatibility issues and possible `/W4 /WX` warnings.
2026-06-19 Desktop CI second-wave failures

- After updating GitHub Actions Flutter SDK to `3.38.3`, dependency resolution moved forward and Desktop Build reached real platform build steps.
- Windows failure:
  - Step: `Build Windows`.
  - Error from Actions log: `firebase_cpp_sdk_windows/CMakeLists.txt:17 (cmake_minimum_required): Compatibility with CMake < 3.5 has been removed from CMake`.
  - Fix: set `CMAKE_POLICY_VERSION_MINIMUM 3.5` in `mobile-app/windows/CMakeLists.txt` so Firebase C++ SDK sub-CMakeLists remains compatible with newer GitHub Actions CMake images.
- macOS failure:
  - Step: `Build macOS`.
  - Error was in CocoaPods dependency resolver (`molinillo`/`cocoapods` stack).
  - Project had macOS plugins but no committed `mobile-app/macos/Podfile`; Firebase podspec explicitly expects users to update/commit macOS Podfile platform settings when needed.
  - Fix: added standard Flutter macOS `Podfile` with `platform :osx, '10.15'`, `flutter_macos_podfile_setup`, `flutter_install_all_macos_pods`, and `flutter_additional_macos_build_settings`.
- Next validation: rerun Desktop Build after this commit; expected next stage is Windows CMake configure past Firebase SDK and macOS CocoaPods resolver past explicit platform.
2026-06-19 Windows C++ compile fixes

- Desktop CI reached Windows C++ compilation after the Firebase/CMake policy fix.
- Windows errors from Actions:
  - `shellapi.h`: parse/redefinition cascade around `EXTERN_C` / `DECLSPEC_IMPORT`.
  - `grani_vpn_channel.cpp`: `IsUserAnAdmin`: identifier not found.
  - `main.cpp`: `DWORD_MAX` undeclared, helper `ReadFile` shadowed WinAPI `ReadFile`, causing wrong overload resolution.
- Fixes:
  - Removed `shellapi.h` dependency from `grani_vpn_channel.cpp`.
  - Replaced `IsUserAnAdmin()` with `IsRunningAsAdmin()` implemented through `AllocateAndInitializeSid` + `CheckTokenMembership`.
  - Renamed service-mode helper from `ReadFile` to `ReadUtf8File`.
  - Called WinAPI as `::ReadFile`.
  - Cast DWORD byte counts to `size_t` in comparisons to avoid `/W4 /WX` warning-as-error.
- macOS still fails in CocoaPods resolver; current screenshot only shows the Ruby stack trace tail, not the actual pod conflict line. Since the immediate product goal is Windows, macOS may need to be made optional/disabled on push if it keeps blocking Desktop workflow success.
2026-06-19 macOS CI follow-up

- Desktop CI after `ccb6f8c`:
  - Windows job passed (green).
  - macOS still failed during `flutter build macos`, specifically during CocoaPods resolver (`molinillo` stack trace). The visible screenshot only shows the stack trace tail, not the `[!] CocoaPods could not find compatible versions...` root line.
- Checked macOS plugin podspecs from pub cache:
  - Current `MACOSX_DEPLOYMENT_TARGET = 10.15`.
  - Firebase macOS podspecs require at most 10.13; Google Sign-In / in_app_purchase require 10.15; WebView requires 10.14. So deployment target is not obviously too low.
- Added `.github/workflows/desktop-build.yml` macOS step `pod repo update` after `flutter pub get` and before `flutter build macos`.
- Rationale: CocoaPods `molinillo` resolver failures in CI are often stale spec repo/CDN metadata; refreshing specs is the least invasive next fix.
- If macOS still fails, next required evidence: search the Actions log for `[!]` or `could not find compatible versions` and capture the conflict block above the Ruby stack trace.
2026-06-19 macOS CI diagnostics/fix

- Windows Desktop job is green; focus moved to macOS.
- `pod repo update` alone did not fix macOS; job still failed in `flutter build macos` with only CocoaPods/molinillo stack trace visible in the screenshot.
- Changed macOS CI to run explicit `pod install --repo-update --verbose` from `mobile-app/macos` before `flutter build macos`.
- Goal: either resolve pods before Flutter build or expose the real CocoaPods conflict block (`[!] ...`) in a dedicated, easier-to-read step.
- Firebase SDK version from FlutterFire is `10.25.0`; current macOS deployment target is `10.15`, which satisfies visible plugin podspec requirements.
## 2026-06-19 01:02 MSK - Desktop CI: expose CocoaPods root conflict

Context:
- GitHub repository: `railtamaew/grani`, branch `main`.
- Windows job in `Desktop Build (Windows + macOS)` is now green after fixing Windows runner compile errors.
- macOS still fails before `flutter build macos`, at CocoaPods dependency resolution.
- GitHub Actions screenshots only show the tail Ruby/Molinillo backtrace:
  - `molinillo/resolution.rb`
  - `cocoapods/resolver.rb`
  - `pod install`
  - `Error: Process completed with exit code 1`
- The actionable CocoaPods `[!] ...` conflict is above the visible tail, so we cannot safely choose a real dependency fix from screenshots alone.

Change made:
- Updated `.github/workflows/desktop-build.yml` macOS `Install macOS pods` step.
- It now runs `pod install --repo-update --verbose` through `tee pod-install.log`.
- On failure it prints:
  - a grouped `CocoaPods failure summary` with grep around `[!]`, compatible-version, spec-source, Firebase/Google/macOS conflict markers;
  - a grouped `CocoaPods tail` with the last 300 lines.

Expected next step:
- Let the GitHub Actions run finish.
- If macOS still fails, inspect the new `CocoaPods failure summary` group or send that block.
- Then fix the actual dependency/version/platform conflict instead of guessing from the Ruby stack tail.
## 2026-06-19 01:25 MSK - macOS CI CocoaPods conflict fixed with Google Sign-In pin

Root cause from GitHub Actions macOS job `Install macOS pods`:
- `firebase_core 2.32.0` / `firebase_messaging 14.7.10` resolve Firebase iOS SDK `10.25.0`.
- Firebase `10.25.0` requires `GoogleUtilities/Environment` in the `7.x` range:
  - `FirebaseCore 10.25.0` -> `GoogleUtilities/Environment (~> 7.12)`
  - `GoogleDataTransport 9.4.1` -> `GoogleUtilities/Environment (~> 7.7)`
  - `FirebaseMessaging 10.25.0` -> `GoogleUtilities/Environment (~> 7.8)`
- `google_sign_in_ios 5.9.0` resolves native `GoogleSignIn (~> 8.0)`.
- `GoogleSignIn 8.0.0` pulls `AppCheckCore 11.3.0`, which requires `GoogleUtilities/Environment (~> 8.0)`.
- CocoaPods cannot satisfy both `GoogleUtilities/Environment 7.x` and `8.x`.

Change made:
- Added `dependency_overrides.google_sign_in_ios: 5.8.0` in `mobile-app/pubspec.yaml`.
- Updated only the `google_sign_in_ios` block in `mobile-app/pubspec.lock`:
  - from `5.9.0` transitive
  - to `5.8.0` direct overridden
- Verified `google_sign_in_ios 5.8.0` podspec depends on native `GoogleSignIn (~> 7.1)`, avoiding the `GoogleUtilities 8.x` branch while current Firebase packages stay on SDK `10.25.x`.

Reason for minimal fix:
- Avoids a broad Firebase/Google Sign-In package upgrade during Windows/macOS platform bring-up.
- Keeps Android/mobile dependency behavior otherwise unchanged.
- Later, when we intentionally upgrade Firebase to the current major versions, remove this override and test OAuth/push flows again.
## 2026-06-19 07:32 MSK - Desktop CI is green

GitHub Actions:
- Workflow: `Desktop Build (Windows + macOS)`
- Run: `Pin Google Sign-In iOS for macOS pods #12`
- Commit: `498dc68`
- Result: success.
- Jobs:
  - `windows`: passed.
  - `macos`: passed.
- Artifacts: 2 (`windows-release`, `macos-release`).

What this confirms:
- Windows Flutter desktop build compiles in GitHub Actions.
- Windows AmneziaWG service-runner path compiles.
- macOS Flutter desktop build compiles in GitHub Actions.
- The CocoaPods conflict between Firebase SDK `10.25.x` and `GoogleSignIn 8.x` was resolved by pinning `google_sign_in_ios` to `5.8.0`.

Current warnings:
- GitHub shows Node.js 20 deprecation warnings for `actions/checkout@v4` and `actions/upload-artifact@v4`.
- These warnings are not blocking; CI still succeeds. Handle later by upgrading Actions versions when upstream releases are available or when GitHub requires it.

Recommended next step:
- Download `windows-release` artifact and smoke-test it on a real Windows machine.
- For the Windows VPN path specifically, verify launch, admin/service creation, AmneziaWG `tunnel.dll` presence, connect/disconnect, and logs.
- Packaging/signing can come after the raw release artifact starts and performs the basic VPN flow.
## 2026-06-19 07:45 MSK - Windows artifact must include AmneziaWG runtime

Finding after downloading `windows-release` artifact from successful GitHub Actions run `#12`:
- Artifact contains `mobile_app.exe`, `flutter_windows.dll`, plugin DLLs, and Flutter assets.
- Artifact does not contain `tunnel.dll`.
- `data/flutter_assets/bin/amneziawg/README.md` is present, but `data/flutter_assets/bin/amneziawg/windows/tunnel.dll` is not.

Why this matters:
- Windows runner code can resolve `tunnel.dll` from either:
  - `data/flutter_assets/bin/amneziawg/windows/tunnel.dll`, or
  - `tunnel.dll` next to `mobile_app.exe`.
- Without `tunnel.dll`, the Windows artifact can start as a Flutter app but cannot exercise the AmneziaWG tunnel service path.

Change made:
- Updated `.github/workflows/desktop-build.yml`.
- Added `Package AmneziaWG Windows runtime` step after `flutter build windows --release`.
- The step verifies:
  - `bin/amneziawg/windows/tunnel.dll` exists after building AmneziaWG Windows sources.
  - `build/windows/x64/runner/Release/mobile_app.exe` exists.
- Then it copies `bin/amneziawg/windows/tunnel.dll` to `build/windows/x64/runner/Release/tunnel.dll`.

Expected next result:
- New `windows-release` artifact should contain `tunnel.dll` next to `mobile_app.exe`.
- This still does not prove VPN works on Windows; it only makes the artifact suitable for the first real Windows smoke test.
## 2026-06-19 07:53 MSK - Windows artifact verified after runtime packaging

GitHub Actions:
- Workflow: `Desktop Build (Windows + macOS)`
- Run: `Package Windows tunnel runtime in desktop artifact`
- Run ID: `27805865238`
- Commit: `39d9efe`
- Result: success.
- Artifacts:
  - `windows-release`: 25.1 MB in GitHub UI, downloaded zip about 25 MB.
  - `macos-release`: 386 MB in GitHub UI.

Windows artifact verification:
- Downloaded `windows-release` artifact locally as `/private/tmp/grani-windows-release-39d9efe.zip`.
- Confirmed these release files exist:
  - `mobile_app.exe` - 826,368 bytes.
  - `flutter_windows.dll` - 18,511,360 bytes.
  - `tunnel.dll` - 5,111,808 bytes.
- `tunnel.dll` is now next to `mobile_app.exe`, matching the Windows runner fallback resolution path.

Status:
- Packaging issue from previous artifact is fixed.
- The artifact is now suitable for first real Windows smoke test.
- This still does not prove VPN connect works; the next step is to run it on Windows with admin rights and observe service creation/connect/disconnect behavior.
