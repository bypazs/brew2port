# brew2port

[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-☕-FFDD00?style=flat)](https://buymeacoffee.com/bypazs)

Migrate your Homebrew formulae to [MacPorts](https://www.macports.org) on **Intel Macs**.

In September 2026 Homebrew moved macOS on Intel x86_64 to [Tier 3](https://docs.brew.sh/Support-Tiers#tier-3). It no longer builds bottles for Intel, so every upgrade compiles from source, the official installer refuses to install on Intel, and Intel support is expected to end entirely in or after September 2027. MacPorts still publishes binary packages for Intel macOS (Sequoia 15 and earlier), so moving your command-line tools there gets you fast, prebuilt installs again.

`brew2port` does that move for you, carefully.

## What it does

1. Backs up your package list (`Brewfile`, formula list, cask list).
2. Reads the formulae you installed yourself (`brew leaves`) and finds the matching MacPorts port for each one, including common name differences (`python@3.12` → `python312`, `node` → `nodejs22`, `gnu-sed` → `gsed`, `openssl@3` → `openssl3`, …).
3. Shows you a plan. **By default it stops here and changes nothing.**
4. With `--apply`, installs each port. With `--uninstall-brew`, it then removes the Homebrew copy, but only after the port installed successfully, and it keeps any formula something else still depends on. Afterwards it runs `brew autoremove` to clear the dependencies nothing needs anymore (often build tools Homebrew pulled in to compile from source on Intel).
5. Checks that `/opt/local/bin` comes before `/usr/local/bin` in your `PATH`.
6. Prints a summary of what moved, what failed and what stayed in Homebrew, and saves it as `summary.txt`.

It never uninstalls Homebrew itself, and it doesn't touch casks: GUI apps you already have in `/Applications` keep working.

## Requirements

- macOS on Intel (x86_64). On Apple Silicon, Homebrew is fully supported and you don't need this.
- Homebrew still installed.
- Xcode Command Line Tools (`xcode-select --install`).
- MacPorts: **optional**. If it's missing, brew2port asks to install it for you: it downloads the official `.pkg` for your macOS version from the MacPorts GitHub releases, checks its SHA256 against the published checksums and its Apple Developer ID signature, and only then installs it. Prefer doing it yourself? Get it from <https://www.macports.org/install.php>.

## Usage

```bash
git clone https://github.com/bypazs/brew2port.git
cd brew2port
chmod +x brew2port.sh

./brew2port.sh                              # 1. dry run: back up + show the plan
./brew2port.sh --apply                      # 2. install the ports, keep Homebrew copies
./brew2port.sh --apply --uninstall-brew     # 3. or install and remove the Homebrew copies
```

Doing step 2 first and checking your tools work before step 3 is the safest route.

| Option | Meaning |
|---|---|
| `--apply` | Actually install the matching ports |
| `--uninstall-brew` | With `--apply`: remove each Homebrew formula after its port installs |
| `--checkup` | Health check for later (see below) |
| `--map FILE` | Your own name overrides (see below) |
| `--yes` | Skip the confirmation prompt |
| `--no-banner` | Skip the startup banner (`NO_COLOR=1` also turns off colors) |
| `--out DIR` | Where backups and the log go (default `~/brew2port-<timestamp>`) |

### When a formula has no match

Rows marked **no match** need a name hint. Find the port with `port search <name>`, then put it in a map file (see `port-map.example.txt`):

```
# <brew-name>   <port-name>
awscli          py313-awscli2
nvm             -              # "-" means skip
```

```bash
./brew2port.sh --map port-map.txt
```

Some tools simply aren't in MacPorts (for example `nvm`, or CLIs from third-party taps like `supabase/tap/supabase`). Skip them and keep the Homebrew copy, or install them another way. Homebrew keeps working on Intel Macs until at least September 2027.

## Keeping it healthy: `--checkup`

Run this every week or two after migrating:

```bash
./brew2port.sh --checkup          # asks before upgrading
./brew2port.sh --checkup --yes    # upgrade without asking
```

It updates MacPorts and its package index, runs `port diagnose`, lists outdated ports and offers to upgrade them, checks your `PATH`, then prints a short summary. If MacPorts isn't installed yet it offers to install it, and it doesn't need Homebrew.

MacPorts, like Homebrew, has no built-in vulnerability scanner. Security fixes arrive as new versions, so upgrading regularly is the main protection. For your projects' own dependencies, use `pip-audit`, `npm audit` and similar.

## PortCat: a menu bar cat for MacPorts

After migrating, [PortCat](PortCat/README.md) keeps an eye on your ports from the menu bar. It sleeps when everything is current, waves with a count when updates are waiting, and lets you upgrade in a click. It can also do the whole move for you: install MacPorts, move your Homebrew formulae, remove the old copies and clean up leftovers, all from buttons.

![PortCat](PortCat/portcat-preview.gif)

```bash
cd PortCat && ./build-app.sh --install
```

## After migrating

- Open a new Terminal window, then check with `which <tool>`: it should point to `/opt/local/bin/...`.
- Day-to-day commands: `port search`, `sudo port install`, `sudo port selfupdate`, `sudo port upgrade outdated`.
- Once everything you need runs from MacPorts, you can remove Homebrew, but remember **it can't be reinstalled on Intel anymore**, so there's no rush.
- Everything the script did is in `brew2port.log` inside the output folder.

## Caveats

- Name mapping is best-effort. Always read the plan before `--apply`.
- Services (e.g. PostgreSQL, Redis) have to be set up again with MacPorts' `port load`; data directories aren't moved.
- MacPorts' binary coverage for Intel on macOS Tahoe 26 is incomplete; on Tahoe some ports may build from source.
- Tested end to end on an Intel MacBook Pro with macOS Sequoia 15.8, plus automated tests with mocked `brew`/`port`. Not yet tried on every macOS version, so issues and PRs are welcome.

---

## ภาษาไทย

สคริปต์ย้ายแพ็กเกจจาก Homebrew ไป MacPorts สำหรับ **Mac ชิป Intel** ซึ่ง Homebrew เลิกซัพพอร์ตแล้ว (Tier 3 ตั้งแต่ กันยายน 2026 ไม่มี bottle ต้อง build เองทุกครั้ง และลงใหม่ไม่ได้)

```bash
./brew2port.sh                            # ดูแผนอย่างเดียว ไม่แตะอะไร
./brew2port.sh --apply                    # ลงตัวใหม่จาก MacPorts (ตัว brew ยังอยู่)
./brew2port.sh --apply --uninstall-brew   # ลงตัวใหม่ แล้วลบตัว brew ทิ้ง
./brew2port.sh --checkup                  # รันทุก 1-2 สัปดาห์: อัปเดต ตรวจปัญหา อัปเกรดตัวที่ตกรุ่น
```

- `--uninstall-brew` เก็บกวาด dependency ที่ค้างของ Homebrew ให้ด้วย (`brew autoremove`)
- ไม่ต้องลง MacPorts เอง ถ้ายังไม่มี script จะถามแล้วลงให้ (ตรวจ checksum และลายเซ็น Apple ก่อนติดตั้ง) หรือจะลงเองจาก <https://www.macports.org/install.php> ก็ได้
- สำรองรายการแพ็กเกจให้อัตโนมัติ ลงตัวใหม่สำเร็จก่อนค่อยลบตัวเก่า และไม่ถอน Homebrew ทิ้ง
- แอป GUI (cask) ไม่ต้องย้าย ใช้ต่อได้ปกติ
- ตัวไหนหาชื่อไม่เจอ ใช้ `port search ชื่อ` แล้วใส่ในไฟล์ `--map`

## Support

If brew2port or PortCat saved your Intel Mac some pain, you can [buy me a coffee ☕](https://buymeacoffee.com/bypazs). Thank you!

## License

MIT
