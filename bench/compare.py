#!/usr/bin/env python3
"""Two-server wrk comparison with the method of docs/design.md section 9 (the performance gate).

Both servers must already run, pinned to the server CPUs (configuration B:
CPUs 0-3), e.g.
    THREADS=4 POOL=1 taskset -c 0-3 build/.../beproto 18081 &
    THREADS=4        taskset -c 0-3 build/.../rawsrv  18082 &
    bench/compare.py beproto 18081 <pid> rawsrv 18082 <pid>

For every cell (c256/c1024 x depth 1/16): a warm-up run per server
(discarded), then RUNS runs of DUR seconds per server, alternating servers
(the first server of the pair alternates from run to run). Per run it records
requests/s, the server's CPU-seconds (/proc/<pid>/stat utime+stime), requests
per server CPU-second, and how busy the server CPUs and the wrk CPUs were
(/proc/stat). A run whose wrk CPUs were more than 90 % busy is client-bound
and flagged; it is left out of the medians (7.6 validity rule, decision 12).
A cell where every run of a server was client-bound has no median (nan) and
the script exits with status 3. Prints every run and a summary with the
median requests/s per server and the ratio B/A per cell.

env: WRK (wrk binary; default: build/tools/bin/wrk from tools/get-tools.sh),
     WRK_CPUS (4-15), WRK_THREADS (12),
     SERVER_CPUS (0-3), RUNS (5), DUR (30), WARM (10),
     CELLS ("256:1 256:16 1024:1 1024:16"), OUT (also append the report to this file)
"""
import os, re, shutil, statistics, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
WRK = os.environ.get('WRK') or os.path.join(os.path.dirname(HERE), 'build', 'tools', 'bin', 'wrk')
CLIENT_BOUND = 90.0
WRK_CPUS = os.environ.get('WRK_CPUS', '4-15')
WRK_THREADS = int(os.environ.get('WRK_THREADS', '12'))
SERVER_CPUS = os.environ.get('SERVER_CPUS', '0-3')
RUNS = int(os.environ.get('RUNS', '5'))
DUR = int(os.environ.get('DUR', '30'))
WARM = int(os.environ.get('WARM', '10'))
CELLS = [tuple(map(int, c.split(':'))) for c in os.environ.get('CELLS', '256:1 256:16 1024:1 1024:16').split()]
HEADERS = ['-H', 'Host: tfb-server',
           '-H', 'Accept: text/plain,text/html;q=0.9,application/xhtml+xml;q=0.9,application/xml;q=0.8,*/*;q=0.7',
           '-H', 'Connection: keep-alive']
TCK = os.sysconf('SC_CLK_TCK')
OUT = os.environ.get('OUT')
REPORT = []


def say(s):
    print(s, flush=True)
    REPORT.append(s)


def cpu_set(spec):
    r = []
    for part in spec.split(','):
        if '-' in part:
            a, b = part.split('-')
            r += list(range(int(a), int(b) + 1))
        else:
            r.append(int(part))
    return r


def proc_stat():
    d = {}
    with open('/proc/stat') as f:
        for line in f:
            if re.match(r'cpu\d+ ', line):
                p = line.split()
                v = list(map(int, p[1:]))
                idle = v[3] + v[4]
                d[int(p[0][3:])] = (sum(v[:8]), idle)
    return d


def busy(a, b, cpus):
    tot = sum(b[c][0] - a[c][0] for c in cpus)
    idle = sum(b[c][1] - a[c][1] for c in cpus)
    return 0.0 if tot == 0 else 100.0 * (tot - idle) / tot


def pid_cpu(pid):
    with open('/proc/%d/stat' % pid) as f:
        p = f.read().rsplit(')', 1)[1].split()
    return (int(p[11]) + int(p[12])) / TCK


def wrk(port, conns, depth, dur):
    cmd = ['taskset', '-c', WRK_CPUS, WRK, '-t%d' % WRK_THREADS, '-c%d' % conns, '-d%ds' % dur,
           '--latency'] + HEADERS + ['-s', os.path.join(HERE, 'pipeline.lua'),
                                     'http://127.0.0.1:%d/plaintext' % port, '--', str(depth)]
    out = subprocess.run(cmd, capture_output=True, text=True).stdout
    m = re.search(r'Requests/sec:\s+([\d.]+)', out)
    rps = float(m.group(1)) if m else 0.0
    errs = ' '.join(l.strip() for l in out.splitlines() if 'Socket errors' in l or 'Non-2xx' in l)
    p99 = re.search(r'^\s+99%\s+(\S+)', out, re.M)
    return rps, errs, (p99.group(1) if p99 else '?')


def run_one(name, port, pid, conns, depth, dur):
    s0, c0 = proc_stat(), pid_cpu(pid)
    rps, errs, p99 = wrk(port, conns, depth, dur)
    s1, c1 = proc_stat(), pid_cpu(pid)
    srv_cpu = c1 - c0
    wb = busy(s0, s1, cpu_set(WRK_CPUS))
    sb = busy(s0, s1, cpu_set(SERVER_CPUS))
    eff = rps * dur / srv_cpu if srv_cpu > 0 else 0
    return dict(rps=rps, srv_cpu=srv_cpu, eff=eff, wrk_busy=wb, srv_busy=sb, errs=errs, p99=p99)


def main():
    if len(sys.argv) != 7:
        sys.exit(__doc__)
    if not os.access(WRK, os.X_OK):
        sys.exit('compare.py: no wrk at %s (run tools/get-tools.sh or set WRK)' % WRK)
    servers = [(sys.argv[1], int(sys.argv[2]), int(sys.argv[3])),
               (sys.argv[4], int(sys.argv[5]), int(sys.argv[6]))]
    gov = open('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor').read().strip() \
        if os.path.exists('/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor') else '?'
    say('# compare.py %s; governor %s; server CPUs %s; wrk CPUs %s x %d threads; %d runs x %d s, warm-up %d s'
        % (time.strftime('%Y-%m-%d %H:%M:%S'), gov, SERVER_CPUS, WRK_CPUS, WRK_THREADS, RUNS, DUR, WARM))
    summary = []
    for conns, depth in CELLS:
        for name, port, pid in servers:
            wrk(port, conns, depth, WARM)
        res = {s[0]: [] for s in servers}
        for r in range(RUNS):
            order = servers if r % 2 == 0 else servers[::-1]
            for name, port, pid in order:
                x = run_one(name, port, pid, conns, depth, DUR)
                res[name].append(x)
                flag = '  CLIENT-BOUND (left out)' if x['wrk_busy'] > CLIENT_BOUND else ''
                say('c=%d d=%d run %d %-8s rps=%11.0f srv_cpu_s=%6.1f req/cpu_s=%9.0f srv_busy=%5.1f%% wrk_busy=%5.1f%% p99=%s %s%s'
                    % (conns, depth, r + 1, name, x['rps'], x['srv_cpu'], x['eff'], x['srv_busy'],
                       x['wrk_busy'], x['p99'], x['errs'], flag))
        a, b = servers[0][0], servers[1][0]
        va = [x for x in res[a] if x['wrk_busy'] <= CLIENT_BOUND]
        vb = [x for x in res[b] if x['wrk_busy'] <= CLIENT_BOUND]
        nan = float('nan')
        ma = statistics.median(x['rps'] for x in va) if va else nan
        mb = statistics.median(x['rps'] for x in vb) if vb else nan
        ea = statistics.median(x['eff'] for x in va) if va else nan
        eb = statistics.median(x['eff'] for x in vb) if vb else nan
        cb = sum(1 for n in res for x in res[n] if x['wrk_busy'] > CLIENT_BOUND)
        summary.append((conns, depth, ma, mb, mb / ma if ma else 0, ea, eb, eb / ea if ea else 0, cb))
    say('')
    a, b = servers[0][0], servers[1][0]
    say('| cell | %s median req/s | %s median req/s | %s / %s | %s req/CPU-s | %s req/CPU-s | ratio | client-bound runs (left out) |'
        % (a, b, b, a, a, b))
    say('|---|---|---|---|---|---|---|---|')
    for conns, depth, ma, mb, r, ea, eb, re_, cb in summary:
        say('| c%d d%d | %.0f | %.0f | %.4f | %.0f | %.0f | %.4f | %d |' % (conns, depth, ma, mb, r, ea, eb, re_, cb))
    if OUT:
        with open(OUT, 'a') as f:
            f.write('\n'.join(REPORT) + '\n')
    if any(x != x for row in summary for x in (row[2], row[3])):
        sys.exit(3)


if __name__ == '__main__':
    main()
