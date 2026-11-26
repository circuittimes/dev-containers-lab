# Dev containers lab

The test files behind the Circuit Times guide to dev containers:
https://circuittimes.com/cloud-dev/dev-containers/

One script starts six small dev container projects with the Dev Container CLI, runs 13 tests against them and prints a transcript. Every test asserts its expected result, so the script stops with an error as soon as a result differs.

## What the tests cover

| Test | What it checks |
|---|---|
| T1, T2 | `devcontainer up` from an image, and the user, folder and environment inside |
| T3 | Files shared both ways between the host and the container |
| T4, T5 | `forwardPorts` and `appPort` when the CLI is used without an editor |
| T6, T7 | Lifecycle command order on first create and after a stop and second `up` |
| T8 | Building from a Dockerfile |
| T9 | A local Feature with an option |
| T10 | An apt-based Feature on an Alpine image, which fails |
| T11 | A plain `docker run` for comparison |
| T12 | The labels the CLI puts on a container |
| T13 | Removing only this run's containers while the project files stay |

## Files

- `run_lab.sh` runs the 13 tests.
- `safety_tests.sh` runs six checks on the lab script itself, such as an interrupted run and containers that belong to someone else.
- `env.sh` is where you set the path to `devcontainer` and `node` if they are not on your path.
- `demo`, `ports`, `steps`, `built`, `feat-local`, `feat-apt` are the six project folders.
- `lab-transcript.txt` and `lab-safety-tests.txt` are the output of our own run.

## Run it

You need Docker, Node.js and the Dev Container CLI (`npm install -g @devcontainers/cli`).

```
bash run_lab.sh
```

The script copies the project folders into a new private folder under `/tmp`, starts every container from there, and removes only the containers it started. Read the script before you run it. It starts and removes containers on your machine.

## Our run

Run on November 25, 2026 on Linux with Docker 29.10.0 and Dev Container CLI 0.90.0. Results on other versions and systems can differ.

Circuit Times used Claude, an AI model made by Anthropic, to help write and run this lab.
