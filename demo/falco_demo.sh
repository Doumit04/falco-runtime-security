#!/usr/bin/env bash
# =====================================================================
#  Falco live demo (Tony Doumit, Administration Unix)
#  Run in the RIGHT terminal as your normal user (not root):
#      bash ~/falco_demo.sh          run the whole demo (Enter = next step)
#      bash ~/falco_demo.sh 4        start at scene 4
#      DRYRUN=1 bash ~/falco_demo.sh print the commands only, run nothing
#  The LEFT terminal shows the alerts:
#      sudo journalctl -u falco-modern-bpf -f -o cat --no-pager | cut -c1-190
#  Everything uses harmless files and stand-ins (copies of "true").
# =====================================================================

DRY="${DRYRUN:-0}"
START="${1:-1}"
RULES=/etc/falco/falco_rules.local.yaml

if [ -t 1 ]; then
  B=$'\e[1m'; G=$'\e[1;32m'; C=$'\e[1;36m'; Y=$'\e[1;33m'; R=$'\e[1;31m'; N=$'\e[0m'
else B=; G=; C=; Y=; R=; N=; fi

if [ "$DRY" != "1" ] && [ "$(id -u)" -eq 0 ]; then
  echo "${R}Run this as your normal user (tony), not as root.${N}"; exit 1
fi

cleanup() {
  [ "$DRY" = "1" ] && return
  rm -f /tmp/demo_suid /tmp/nmap /tmp/systemctl /tmp/john /tmp/lighttpd /dev/shm/hello_shm
  sudo rm -f /etc/falco/demo.txt
}
trap cleanup EXIT

scene() {
  echo; echo "${B}==================================================${N}"
  echo "${B}  Scene $1: $2${N}"
  echo "${B}==================================================${N}"
  echo "  ${C}Expect on the LEFT:${N} $3"
}
step() {
  if [ "$DRY" = "1" ]; then echo "\$ $1"; return; fi
  read -r -p "  ${Y}[Enter to run]${N} " _
  echo "${B}\$ $1${N}"
  eval "$1"
  echo "  ${G}-> now look at the LEFT terminal${N}"; echo
}

if [ "$DRY" != "1" ]; then
  echo "${B}Pre-flight checks...${N}"
  if [ "$(systemctl is-active falco-modern-bpf)" != "active" ]; then
    echo "${R}Falco is not active. Stop here.${N}"; exit 1; fi
  echo "  Falco: ${G}active${N}"
  sudo -v || exit 1
  command -v hydra >/dev/null && echo "  hydra: ${G}found${N}" || echo "  hydra: ${R}NOT FOUND (scene 7 will fail)${N}"
  HASH_BEFORE=$(sudo sha256sum "$RULES" | cut -d' ' -f1)
  echo "  Rules file fingerprint saved."
fi

scene_1() { scene 1 "Default rule 1: read the password file" "WARNING, sensitive file opened by non-trusted program (/etc/shadow, process=cat)"
  step 'sudo cat /etc/shadow > /dev/null'; }
scene_2() { scene 2 "Rule A: the setuid bit, then a silent control" "WARNING for the setuid bit; NO alert when the bit is removed"
  step 'touch /tmp/demo_suid && chmod 755 /tmp/demo_suid && chmod u+s /tmp/demo_suid && ls -l /tmp/demo_suid'
  step 'chmod 600 /tmp/demo_suid && ls -l /tmp/demo_suid'; }
scene_3() { scene 3 "Rule B: a scanner, as me and with sudo (stand-in named nmap)" "CRITICAL both times (login id is still mine, not 0)"
  step 'cp /bin/true /tmp/nmap && /tmp/nmap -sV -p 22,80 127.0.0.1'
  step 'sudo /tmp/nmap -sV -p 22,80 127.0.0.1'; }
scene_4() { scene 4 "Rule C1: a normal user tries to write in the Falco folder" "'Permission denied' here, CRITICAL alert on the left"
  step 'echo "# demo" >> /etc/falco/falco_rules.local.yaml'
  if [ "$DRY" != "1" ]; then
    [ "$(sudo sha256sum "$RULES" | cut -d' ' -f1)" = "${HASH_BEFORE:-x}" ] && echo "  ${G}Rules file unchanged: OK${N}" || echo "  ${R}WARNING: the rules file changed!${N}"
  fi; }
scene_5() { scene 5 "Rules C2 and C3: write, then delete, in the Falco folder" "WARNING for the write, then WARNING for the delete"
  step "sudo sh -c 'echo demo > /etc/falco/demo.txt'"
  step 'sudo rm /etc/falco/demo.txt'; }
scene_6() { scene 6 "Rule C4: try to disable Falco (stand-in named systemctl)" "ALERT, the highest level (Falco keeps running)"
  step 'cp /bin/true /tmp/systemctl && /tmp/systemctl disable falco-modern-bpf'
  [ "$DRY" != "1" ] && echo "  Falco is still: $(systemctl is-active falco-modern-bpf)"; }
scene_7() { scene 7 "Rule D: a real attack tool (hydra, help only)" "ALERT for an attack tool (nothing is attacked)"
  step 'hydra -h 2>&1 | head -3'; }
scene_8() { scene 8 "Rule B, lower level: a simulated root login" "WARNING (lower), because the login id is 0"
  step "sudo bash -c 'echo 0 > /proc/self/loginuid; /tmp/nmap'"; }
scene_9() { scene 9 "Rule D: a stand-in named john" "alert for an attack tool"
  step 'cp /bin/true /tmp/john && /tmp/john'; }
scene_10() { scene 10 "Default rule 2: a shell under a fake web server" "NOTICE, shell spawned by untrusted binary"
  step "cp /bin/bash /tmp/lighttpd && /tmp/lighttpd -c 'sh -c \"echo hello from a shell\"; echo done'"; }
scene_11() { scene 11 "Default rule 3: a program run from /dev/shm" "WARNING, file execution detected from /dev/shm"
  step 'cp /bin/echo /dev/shm/hello_shm && /dev/shm/hello_shm "hello from /dev/shm"'; }

for n in 1 2 3 4 5 6 7; do [ "$n" -ge "$START" ] && "scene_$n"; done

if [ "$DRY" = "1" ]; then ANS=y; else echo; read -r -p "${Y}Run the extra scenes 8 to 11? [y/N]${N} " ANS; fi
if [ "$ANS" = "y" ] || [ "$ANS" = "Y" ]; then
  # scene 8 needs the nmap stand-in
  [ "$DRY" != "1" ] && [ ! -e /tmp/nmap ] && cp /bin/true /tmp/nmap
  for n in 8 9 10 11; do "scene_$n"; done
fi

if [ "$DRY" != "1" ]; then
  echo; echo "${B}Cleaning up the stand-ins...${N}"; cleanup
  echo "${G}Done. Falco is still running: $(systemctl is-active falco-modern-bpf)${N}"
fi
