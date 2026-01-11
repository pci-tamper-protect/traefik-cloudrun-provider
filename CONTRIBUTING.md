# Contributing to Traefik Cloud Run Provider

Thank you for your interest in contributing! This document provides guidelines and instructions for contributing to the project.

## Code of Conduct

### Our Pledge

We are committed to providing a welcoming and inclusive environment for all contributors, regardless of experience level, background, or identity.

### Expected Behavior

- Be respectful and considerate in communication
- Provide constructive feedback
- Focus on what is best for the community
- Show empathy towards other contributors

### Unacceptable Behavior

- Harassment, discrimination, or offensive comments
- Trolling or insulting/derogatory comments
- Personal or political attacks
- Publishing others' private information

## How to Contribute

### Reporting Bugs

Before creating a bug report, please check existing issues to avoid duplicates.

**Bug Report Template:**

```markdown
**Description**
A clear description of the bug.

**Steps to Reproduce**
1. Step one
2. Step two
3. Step three

**Expected Behavior**
What you expected to happen.

**Actual Behavior**
What actually happened.

**Environment**
- Go version:
- GCP project:
- Cloud Run region:
- Operating system:

**Logs**
```
Relevant log output
```
```

### Suggesting Features

Feature suggestions are welcome! Please provide:

- Clear use case description
- Expected behavior
- Why this feature would be valuable
- Potential implementation approach (if you have ideas)

### Pull Request Process

#### 1. Setup Development Environment

```bash
# Fork and clone the repository
git clone https://github.com/YOUR_USERNAME/traefik-cloudrun-provider
cd traefik-cloudrun-provider

# Install development tools
make install-tools

# Install pre-commit hooks
make pre-commit-install

# Set up GCP authentication for testing
gcloud auth application-default login
```

#### 2. Create a Branch

```bash
# Create a feature branch
git checkout -b feature/your-feature-name

# Or a bugfix branch
git checkout -b fix/bug-description
```

Branch naming conventions:
- `feature/` - New features
- `fix/` - Bug fixes
- `docs/` - Documentation improvements
- `refactor/` - Code refactoring
- `test/` - Test improvements

#### 3. Make Your Changes

**Development Workflow:**

```bash
# Make changes to code

# Format code
make fmt

# Run linters
make lint

# Run tests
make test

# Check coverage
make coverage
```

**Coding Standards:**

- Follow Go standard formatting (`gofmt`)
- Write clear, descriptive variable and function names
- Add comments for complex logic
- Keep functions focused and small
- Handle errors explicitly
- Write tests for new functionality
- Update documentation as needed

**Commit Guidelines:**

Write clear, descriptive commit messages:

```bash
# Good commit messages
git commit -m "Add token caching to reduce API calls"
git commit -m "Fix race condition in service discovery"
git commit -m "Update README with troubleshooting section"

# Poor commit messages (avoid)
git commit -m "fix bug"
git commit -m "updates"
git commit -m "WIP"
```

Commit message format:
- Use imperative mood ("Add feature" not "Added feature")
- First line is a brief summary (50 chars or less)
- Add detailed explanation in body if needed
- Reference issues: "Fixes #123" or "Related to #456"

#### 4. Run All Quality Checks

Before submitting, ensure all checks pass:

```bash
# Run comprehensive check
make check

# Or run CI checks locally
make ci

# Run E2E tests
make e2e-test
```

Pre-commit hooks will automatically run on `git commit`, but you can run them manually:

```bash
make pre-commit-run
```

#### 5. Submit Pull Request

1. **Push to your fork:**
```bash
git push origin feature/your-feature-name
```

2. **Create pull request on GitHub**

3. **Fill out PR template:**

```markdown
## Description
Brief description of changes.

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Breaking change
- [ ] Documentation update

## Testing
- [ ] Unit tests pass
- [ ] E2E tests pass
- [ ] Manual testing performed

## Checklist
- [ ] Code follows project style guidelines
- [ ] Self-review completed
- [ ] Comments added for complex code
- [ ] Documentation updated
- [ ] No new warnings generated
- [ ] Tests added/updated
- [ ] All tests pass
```

4. **Address review feedback:**
- Respond to comments
- Make requested changes
- Push updates to same branch
- Request re-review when ready

#### 6. After Merge

After your PR is merged:
- Delete your feature branch
- Pull latest changes from main
- Celebrate your contribution!

## Development Guidelines

### Project Structure

```
traefik-cloudrun-provider/
├── cmd/
│   └── provider/           # Main application entry point
├── provider/               # Core provider logic
│   ├── provider.go        # Provider interface implementation
│   ├── discovery.go       # Service discovery
│   ├── labels.go          # Label parsing
│   └── config.go          # Configuration generation
├── internal/
│   ├── gcp/               # GCP SDK wrappers
│   └── logging/           # Logging utilities
├── tests/
│   └── e2e/               # End-to-end tests
├── docs/                  # Additional documentation
└── deploy/                # Deployment configurations
```

### Testing Requirements

All contributions should include appropriate tests:

**Unit Tests:**
- Test public functions and methods
- Mock external dependencies (Cloud Run API, metadata server)
- Test edge cases and error conditions
- Aim for >80% code coverage

**Integration Tests:**
- Test against real Cloud Run services (in test project)
- Verify end-to-end flows
- Test authentication and authorization

**E2E Tests:**
- Test complete deployment scenarios
- Verify Traefik integration
- Test service-to-service communication

### Documentation Requirements

Update documentation for:
- New features (README.md, relevant docs)
- API changes (function signatures, parameters)
- Configuration changes (traefik.yml, environment variables)
- Breaking changes (MIGRATION.md)

### Performance Considerations

- Minimize API calls to Cloud Run
- Use caching where appropriate
- Avoid blocking operations in hot paths
- Profile code for bottlenecks if needed

### Security Guidelines

- Never log sensitive data (tokens, credentials)
- Validate all external input
- Use least-privilege IAM permissions
- Follow GCP security best practices
- Sanitize labels before parsing

## Release Process

Releases are managed by maintainers. The process:

1. **Version Bump**
   - Update version in code
   - Update CHANGELOG.md

2. **Create Release Tag**
   ```bash
   git tag -a v1.2.0 -m "Release v1.2.0"
   git push origin v1.2.0
   ```

3. **GitHub Release**
   - Create GitHub release from tag
   - Add release notes
   - Attach binaries

4. **Announcement**
   - Update documentation
   - Announce in discussions

## Getting Help

- **Questions:** Open a [GitHub Discussion](https://github.com/pci-tamper-protect/traefik-cloudrun-provider/discussions)
- **Bugs:** Open a [GitHub Issue](https://github.com/pci-tamper-protect/traefik-cloudrun-provider/issues)
- **Security:** Email maintainers privately (see SECURITY.md)

## Resources

- [Go Code Review Comments](https://github.com/golang/go/wiki/CodeReviewComments)
- [Effective Go](https://golang.org/doc/effective_go)
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [Cloud Run Documentation](https://cloud.google.com/run/docs)

## Recognition

Contributors will be recognized in:
- GitHub contributors page
- Release notes for significant contributions
- Special mentions for major features

Thank you for contributing to traefik-cloudrun-provider!
