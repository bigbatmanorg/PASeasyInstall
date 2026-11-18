#!/usr/bin/env python3
"""Isolated source/NTFS-equivalent POSIX/real-sshd parser checks; NO PSMP install/auth.
Run sudo -n python3 Tests/LinuxUbuntuPSMPBaseline.Contract.py. Never changes OS policy.
"""
import os, pathlib, subprocess, tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
task=(repo/'PASeasyInstall/Recipes/LinuxComponent/Task.sh').read_text()
verify=(repo/'PASeasyInstall/Recipes/LinuxComponent/Verify.sh').read_text()
def block(s): return s.split('# BEGIN PAEASY_UBUNTU24_PSMP_BASELINE')[1].split('\n',1)[1].split('# END PAEASY_UBUNTU24_PSMP_BASELINE')[0]
assert block(task)==block(verify), 'independent payload closure differs'
assert os.geteuid()==0, 'isolated root-owned /run fixture requires sudo'
count=1
with tempfile.TemporaryDirectory(prefix='paeasy-ubuntu-contract-',dir='/run') as directory:
 p=pathlib.Path(directory)
 def bash(code,ok=True):
  global count
  r=subprocess.run(['bash','-c','set -Eeuo pipefail\n'+block(task)+'\n'+code],capture_output=True,text=True)
  assert (r.returncode==0)==ok,(code,r.returncode,r.stderr[:200]);count+=1
 bash('ID=ubuntu;VERSION_ID=22.04;psmp_ubuntu_native',False)
 bash("ID=ubuntu;VERSION_ID=24.04;dpkg-query(){ printf 'install ok installed 15.0.0.5';return 7; };psmp_ubuntu_native",False)
 bash("ID=ubuntu;VERSION_ID=24.04;dpkg-query(){ printf 'install ok installed 15.0.0.5'; };psmp_ubuntu_trusted(){ :; };sha256sum(){ echo 'd548f57b38da4cb2ff3bb224720e95052e2e004d9bd7bd3272e2b9b1414c60bb fixture';return 7; };psmp_ubuntu_native",False)

 file=p/'policy';file.write_text('fixture\n');file.chmod(0o644)
 bash(f'psmp_ubuntu_trusted {file}')
 # Plausible stdout cannot excuse a failed native metadata query.
 bash(f'stat() {{ printf "0\\n";return 7; }};psmp_ubuntu_trusted {file}',False)
 bash(f'stat() {{ if [[ $2 = %u ]];then echo 0;else echo 644;return 7;fi; }};psmp_ubuntu_trusted {file}',False)
 file.chmod(0o666);bash(f'psmp_ubuntu_trusted {file}',False);file.chmod(0o644)
 os.chown(file,65534,65534);bash(f'psmp_ubuntu_trusted {file}',False);os.chown(file,0,0)
 subprocess.run(['setfacl','-m','u:65534:r',str(file)],check=True)
 bash(f'psmp_ubuntu_trusted {file}',False);subprocess.run(['setfacl','-b',str(file)],check=True)
 link=p/'link';link.symlink_to(file);bash(f'psmp_ubuntu_trusted {link}',False)
 apply=task.split('psmp_ubuntu_publish() {',1)[1].split('psmp_local_readiness() {',1)[0]
 publisher='psmp_ubuntu_publish() {'+apply
 dest=p/'published'
 bash(publisher+f'\npsmp_ubuntu_publish {dest} psmp_ubuntu_ssh_content')
 original=dest.read_bytes()
 bash(publisher+f'\npsmp_ubuntu_publish {dest} psmp_ubuntu_ssh_content')
 dest.write_text('unrecognized planted policy\n')
 bash(publisher+f'\npsmp_ubuntu_publish {dest} psmp_ubuntu_ssh_content',False)
 assert dest.read_text()=='unrecognized planted policy\n';count+=1
 # Parse genuine OpenSSH Match/Include syntax with synthetic, throwaway host key.
 subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(p/'hostkey')],check=True)
 own=p/'00-own.conf';own.write_bytes(original)
 native=p/'20-CARKpsmp.conf';native.write_text('UseDNS no\nUsePAM yes\nKbdInteractiveAuthentication yes\n')
 config=p/'sshd_config';config.write_text(f'HostKey {p}/hostkey\nInclude {own}\nInclude {native}\n')
 def effective(user):
  r=subprocess.run(['/usr/sbin/sshd','-T','-f',str(config),'-C',f'user={user},host=localhost,addr=127.0.0.1'],capture_output=True,text=True)
  assert r.returncode==0,r.stderr
  return set(r.stdout.splitlines())
 root=effective('root');ordinary=effective('nobody')
 assert {'authenticationmethods publickey','disableforwarding yes','kbdinteractiveauthentication no','passwordauthentication no'}<=root;count+=1
 assert {'usepam yes','kbdinteractiveauthentication yes','disableforwarding no','allowtcpforwarding yes','allowstreamlocalforwarding yes'}<=ordinary;count+=1
 # Effective configuration failure is independent of completion markers/native service mocks.
 outputs='''systemctl(){ return 0; };sysctl(){ [[ $* = *randomize* ]] && echo 2 || echo 0; }
/usr/sbin/sshd(){ if [[ $1 = -t ]];then return 0;fi;printf '%s\n' 'permitrootlogin without-password' 'pubkeyauthentication yes' 'authenticationmethods publickey' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'disableforwarding yes' 'permitemptypasswords no' 'x11forwarding no' 'permittunnel no' 'gatewayports no'; }
'''
 # Mock root-only output cannot pass the independent broker forwarding/PAM context.
 bash(outputs+'psmp_ubuntu_effective',False)
 good=outputs.split('/usr/sbin/sshd()',1)[0]+r"""
/usr/sbin/sshd(){
 if [[ $1 = -t ]];then return 0;fi
 if [[ $* = *user=root,* ]];then printf '%s\n' 'permitrootlogin without-password' 'pubkeyauthentication yes' 'authenticationmethods publickey' 'passwordauthentication no' 'kbdinteractiveauthentication no' 'disableforwarding yes' 'permitemptypasswords no' 'x11forwarding no' 'permittunnel no' 'gatewayports no'
 else printf '%s\n' 'usepam yes' 'kbdinteractiveauthentication yes' 'disableforwarding no' 'allowtcpforwarding yes' 'allowstreamlocalforwarding yes';fi
}
"""
 bash(good+'psmp_ubuntu_effective')
 bash(good+'\nsysctl(){ [[ $* = *randomize* ]] && echo 2 || echo 0;return 7; };psmp_ubuntu_effective',False)
 bash(good.replace("'authenticationmethods publickey'","'authenticationmethods any'")+'psmp_ubuntu_effective',False)
 bash(good.replace("'allowtcpforwarding yes'","'allowtcpforwarding no'")+'psmp_ubuntu_effective',False)
 bash(good.replace('echo 2','echo 1')+'psmp_ubuntu_effective',False)
 bash(good+'\n/usr/sbin/sshd(){ return 1; };psmp_ubuntu_effective',False)
 assert 'psmp_ubuntu_baseline_valid' in verify.split('  Harden)',1)[1].split('  Register)',1)[0];count+=1
# Exercise the actual Register case body with synthetic vendor executables only.
# No OS paths or Vault endpoints are reachable from this substituted fixture.
register=task.split('  Register)\n',1)[1].split('  Harden)\n',1)[0]
for native_ok,ready_ok,expected in ((True,True,True),(False,True,False),(True,False,False)):
 with tempfile.TemporaryDirectory(prefix='paeasy-register-order-',dir='/tmp') as directory:
  p=pathlib.Path(directory);binpath=p/'vendor/bin';binpath.mkdir(parents=True)
  conf=p/'conf/vault';conf.mkdir(parents=True);(conf/'vault.ini').write_text('ADDRESS=fixture\n')
  event=p/'events';event.write_text('');envelope=p/'inputs.json';envelope.write_text('{}')
  create=binpath/'createcredfile';create.write_text('#!/bin/bash\nset -eu\nprintf fixture > "$1"\nprintf fixture > "$1.entropy"\nprintf "createcred\\n" >> "$FIXTURE_EVENTS"\n');create.chmod(0o700)
  finalize=binpath/'psmp_setup.sh';finalize.write_text('#!/bin/bash\nset -eu\nprintf "finalize\\n" >> "$FIXTURE_EVENTS"\n');finalize.chmod(0o700)
  body=register.replace('/etc/opt/CARKpsmp',str(p/'conf')).replace('/opt/CARKpsmp',str(p/'vendor'))
  setup=f'''type=PSMP;ID=ubuntu;harden=true;password=NONSECRET_FIXTURE;user=fixture;vault=192.0.2.1
PAEASY_INPUT_JSON={envelope};export FIXTURE_EVENTS={event}
options() {{ :; }};hostname() {{ echo fixturehost; }};systemctl() {{ :; }};sleep() {{ :; }}
psmp_ubuntu_native() {{ {'true' if native_ok else 'false'}; }}
psmp_local_readiness() {{ {'true' if ready_ok else 'false'}; }}
psmp_ubuntu_baseline_valid() {{ echo PREMATURE_BASELINE_CHECK >&2; return 99; }}
success() {{ echo REGISTERED_WITHOUT_HARDENING_CLAIM; }}
'''
  result=subprocess.run(['bash','-c','set -Eeuo pipefail\n'+setup+'\ncase Register in Register)\n'+body+'\nesac'],capture_output=True,text=True)
  assert (result.returncode==0)==expected,(result.returncode,result.stderr)
  assert 'PREMATURE_BASELINE_CHECK' not in result.stderr
  assert ('finalize' in event.read_text())==native_ok
  assert ('REGISTERED_WITHOUT_HARDENING_CLAIM' in result.stdout)==expected
  assert 'NONSECRET_FIXTURE' not in result.stdout+result.stderr
  count+=1

print(f'{count} Ubuntu PSMP isolated contracts PASS; native PSMP/broker/reboot NotTested')
