This directory contains a collection of **P** projects used to verify OSWALD
design. See the [P website](https://p-org.github.io/P) for more details about
the P language and tools.

## Cheat sheet

### Multithreaded checking

```sh
p compile

# Run 10 checks of the `concurrentCounters` test case with 1000 schedules each:
seq 10 | parallel --tag --line-buffer --color --halt now,fail=1 \
    p check --testcase concurrentCounters --schedules 1000 --outdir PCheckerOutput/{}
```
