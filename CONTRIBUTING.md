# 🔧 Contributing to Itential Dev Stack

Thank you for your interest in contributing! This guide covers the fork-and-pull workflow for submitting changes.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (v20.10+) or [Podman](https://podman.io/docs/installation) (v4.0+)
- [Git](https://git-scm.com/downloads)
- A [GitHub](https://github.com) account
- GPG or SSH key configured for [commit signing](https://docs.github.com/en/authentication/managing-commit-signature-verification)

## Fork and Pull Workflow

All contributions use the fork-and-pull model. Never commit directly to the main repository.

### 1. Fork the Repository

Click **Fork** on the [repository page](https://github.com/itential/itential-dev-stack) to create your copy.

### 2. Clone Your Fork

```bash
git clone https://github.com/YOUR_USERNAME/itential-dev-stack.git
cd itential-dev-stack
```

### 3. Add Upstream Remote

```bash
git remote add upstream https://github.com/itential/itential-dev-stack.git
git fetch upstream
```

### 4. Create a Feature Branch

Always branch from an up-to-date `main`:

```bash
git checkout main
git pull upstream main
git checkout -b feature/your-feature-name
```

**Branch naming conventions:**

| Prefix | Use Case |
|--------|----------|
| `feature/`  | New features or enhancements |
| `fix/`      | Bug fixes |
| `docs/`     | Documentation changes |
| `chore/`    | Maintenance, dependencies, CI |

### 5. Make Your Changes

Edit files and test your changes:

```bash
# Fresh environment test
make clean && make setup

# Or test with a specific profile
docker compose --profile platform up -d
```

> **Note**: Test with relevant Docker Compose profiles (`deps`, `platform`, `gateway4`, `gateway5`, `full`) to ensure your changes work correctly.

### 6. Commit Your Changes

Use [conventional commits](https://www.conventionalcommits.org/):

```bash
git add .
git commit -S -m "feat: add support for this great thing"
```

**Commit format:** `<type>: <subject>`

| Type | Description |
|------|-------------|
| `feat`      | New feature |
| `fix`       | Bug fix |
| `docs`      | Documentation only |
| `style`     | Formatting, no code change |
| `refactor`  | Code restructuring |
| `test`      | Adding or updating tests |
| `chore`     | Maintenance tasks |
| `perf`      | Performance improvements |

**Rules:**
- Subject line: 50 characters or less, imperative mood, no period
- Breaking changes: add `!` after type (e.g., `feat!: remove deprecated config`)

**Signed commits required:** All commits must be cryptographically signed. Configure Git to sign by default:

```bash
git config --global commit.gpgsign true
```

See GitHub's [commit signing guide](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits) for GPG/SSH key setup.

### 7. Push to Your Fork

```bash
git push origin feature/your-feature-name
```

### 8. Open a Pull Request

1. Go to your fork on GitHub
2. Click **Compare & pull request**
3. Target the `main` branch of the upstream repository
4. Fill out the PR template
5. Submit the pull request

### 9. Address Review Feedback

Respond to comments and push additional commits:

```bash
git add .
git commit -m "fix: address review feedback"
git push origin feature/your-feature-name
```

### 10. After Merge

Clean up your local branches:

```bash
git checkout main
git pull upstream main
git branch -d feature/your-feature-name
```

## Code Style

### Shell Scripts

- Use `set -e` for fail-fast behavior
- Include color-coded logging with `log_info`, `log_warn`, `log_error` functions
- Support `--help`, `--force`, and `--quiet` flags where appropriate
- Make scripts idempotent (safe to run multiple times)

### Markdown

- Use `> **Note**:` for important callouts
- Use tables for reference material
- Include `bash` language specifier for code blocks

### Configuration

- Add new variables to `.env.example` with comments
- Use sensible defaults
- Document required vs optional variables

## Testing Checklist

Before submitting:

- [ ] Code follows the project's style guidelines
- [ ] Self-review of code has been performed
- [ ] Code has been commented where necessary
- [ ] Tested with `make setup` or relevant profile
- [ ] Commits follow conventional format (`type: subject`)
- [ ] No secrets or credentials committed
- [ ] Documentation has been updated accordingly

## Getting Help

- Review existing [issues](https://github.com/itential/itential-dev-stack/issues) for similar questions
- Open a new issue for bugs or feature requests
- Check the [README](README.md) for usage documentation
