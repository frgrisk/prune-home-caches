Name:           prune-home-caches
Version:        1.0.0
Release:        1%{?dist}
Summary:        Weekly pruning of stale build caches under /home

License:        MIT
URL:            https://github.com/frgrisk/prune-home-caches
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

Requires:       bash >= 4.2
Requires:       coreutils
Requires:       findutils
Requires:       gawk
Requires:       procps-ng
Requires:       systemd

%description
Reclaims disk space on the /home mount in three stages:

  builds    stale VS Code Remote server builds and superseded Claude Code
            binaries, subject to an age gate, never removing a build that is
            in use by a running process or is the newest for that user
  cache     every user's ~/.cache, cleared wholesale
  modcache  every user's ~/go/pkg/mod, cleared wholesale

VS Code Remote never garbage-collects its server builds, keeping one directory
per release per user indefinitely; on a shared development host this is
typically the dominant consumer of /home.

Installs a systemd timer that runs weekly with Persistent=true, so a run missed
while the host was powered off is performed after the next boot. The service is
sandboxed with ProtectSystem=strict and ReadWritePaths=/home.

A test harness is included which exercises the script against a throwaway
fixture tree and never touches the real /home.

%prep
%setup -q

%build
# Nothing to build; validate syntax so a broken script cannot be packaged.
bash -n src/prune-home-caches.sh
bash -n src/test-prune-home-caches.sh

%install
rm -rf %{buildroot}
install -D -m 0755 src/prune-home-caches.sh \
    %{buildroot}%{_sbindir}/prune-home-caches.sh
install -D -m 0755 src/test-prune-home-caches.sh \
    %{buildroot}%{_sbindir}/test-prune-home-caches.sh
install -D -m 0644 systemd/prune-home-caches.service \
    %{buildroot}%{_unitdir}/prune-home-caches.service
install -D -m 0644 systemd/prune-home-caches.timer \
    %{buildroot}%{_unitdir}/prune-home-caches.timer
install -D -m 0644 README.md \
    %{buildroot}%{_docdir}/%{name}/README.md
install -D -m 0644 LICENSE \
    %{buildroot}%{_licensedir}/%{name}/LICENSE

%files
%{_sbindir}/prune-home-caches.sh
%{_sbindir}/test-prune-home-caches.sh
%{_unitdir}/prune-home-caches.service
%{_unitdir}/prune-home-caches.timer
%doc %{_docdir}/%{name}/README.md
%license %{_licensedir}/%{name}/LICENSE

%post
systemctl daemon-reload >/dev/null 2>&1 || :
if [ $1 -eq 1 ]; then
    # Initial install only. Enable but do NOT start: the timer arms itself,
    # and starting the timer unit is what schedules the first run.
    systemctl enable --now prune-home-caches.timer >/dev/null 2>&1 || :
    echo "prune-home-caches: timer enabled. Next run:"
    systemctl list-timers prune-home-caches.timer --no-pager 2>/dev/null | sed -n 2p || :
    echo "Preview with: prune-home-caches.sh --dry-run"
fi

%preun
if [ $1 -eq 0 ]; then
    # Full removal, not an upgrade.
    systemctl disable --now prune-home-caches.timer >/dev/null 2>&1 || :
fi

%postun
systemctl daemon-reload >/dev/null 2>&1 || :
if [ $1 -ge 1 ]; then
    # Upgrade: pick up any unit file changes without disturbing the schedule.
    systemctl try-restart prune-home-caches.timer >/dev/null 2>&1 || :
fi

%changelog
* Thu Aug 13 2026 Henry Skiba <henry.skiba@frgrisk.com> - 1.0.0-1
- Initial package.
- Three stages: builds (age-gated), cache and modcache (wholesale).
- systemd timer, weekly, Persistent=true.
- Includes fixture-based test harness.
