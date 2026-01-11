# Publishing Checklist

This document tracks readiness for publishing traefik-cloudrun-provider to various catalogs and registries.

## Publication Targets

### 1. GitHub Repository (Public)

**Purpose:** Open-source hosting, issue tracking, contributions

#### Requirements
- [x] LICENSE file (MIT)
- [x] README.md with clear description
- [x] CONTRIBUTING.md guidelines
- [x] Code of conduct (in CONTRIBUTING.md)
- [x] Documentation (DESIGN.md, TESTING.md, MIGRATION.md)
- [x] .gitignore configured
- [x] CI/CD pipeline (.github/workflows/ci.yml)
- [ ] **Git remote configured** (needs GitHub repo URL)
- [ ] **All changes committed**
- [ ] **Pushed to GitHub**

**Status:** ⚠️ **Ready but not yet published**

**Action Required:**
```bash
# Create GitHub repository first, then:
git remote add origin https://github.com/kestenbroughton/traefik-cloudrun-provider.git
git add .
git commit -m "Initial release: v1.0.0"
git push -u origin main
```

---

### 2. Go Package Registry (pkg.go.dev)

**Purpose:** Go module discovery, documentation hosting

#### Requirements
- [x] Valid go.mod with module path
- [x] Go 1.21+ compatibility
- [x] LICENSE file
- [x] README.md
- [x] Package documentation (godoc comments)
- [x] Tests passing
- [ ] **Published to GitHub**
- [ ] **Version tag (v1.0.0)**

**Status:** ⚠️ **Ready but not yet tagged**

**How it works:**
- Automatically indexed when you push a version tag to GitHub
- No manual submission needed
- Available at: https://pkg.go.dev/github.com/kestenbroughton/traefik-cloudrun-provider

**Action Required:**
```bash
# After pushing to GitHub:
git tag -a v1.0.0 -m "Release v1.0.0: Production-ready Cloud Run provider"
git push origin v1.0.0

# pkg.go.dev will automatically index it within a few minutes
```

---

### 3. GitHub Releases

**Purpose:** Binary distribution, release notes, changelog

#### Requirements
- [x] Repository on GitHub
- [x] VERSION or version tag
- [x] Release notes / changelog
- [x] Build artifacts (binaries)
- [ ] **Release workflow** (.github/workflows/release.yml)
- [ ] **First release created**

**Status:** ⚠️ **Needs release workflow**

**Action Required:**

1. **Create Release Workflow** (.github/workflows/release.yml):
```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version: '1.21'

      - name: Build binaries
        run: |
          # Linux
          GOOS=linux GOARCH=amd64 go build -o bin/traefik-cloudrun-provider-linux-amd64 ./cmd/provider
          GOOS=linux GOARCH=arm64 go build -o bin/traefik-cloudrun-provider-linux-arm64 ./cmd/provider

          # macOS
          GOOS=darwin GOARCH=amd64 go build -o bin/traefik-cloudrun-provider-darwin-amd64 ./cmd/provider
          GOOS=darwin GOARCH=arm64 go build -o bin/traefik-cloudrun-provider-darwin-arm64 ./cmd/provider

      - name: Create Release
        uses: softprops/action-gh-release@v1
        with:
          files: bin/*
          generate_release_notes: true
```

2. **Create Release:**
```bash
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
# GitHub Actions will build binaries and create release
```

---

### 4. Traefik Plugin Catalog (Future)

**Purpose:** Native Traefik plugin integration

#### Requirements
- [ ] Restructure as Traefik plugin (not standalone binary)
- [ ] .traefik.yml plugin manifest
- [ ] Plugin API implementation
- [ ] Traefik plugin requirements met
- [ ] Submit to Traefik Plugin Catalog

**Status:** ❌ **Not Applicable (Current Architecture)**

**Why:**
- Current design is a standalone binary that generates config files
- Traefik plugins require different architecture (run inside Traefik process)
- Would need significant refactoring to become a plugin

**Future Consideration:**
Could be restructured as plugin in v2.0 for:
- Continuous polling without external binary
- Native Traefik integration
- No Cloud Scheduler needed

---

### 5. Docker Hub / Container Registry

**Purpose:** Pre-built container images

#### Requirements
- [x] Dockerfile
- [x] Docker build working
- [x] Multi-stage build
- [ ] **Docker Hub account / GCR project**
- [ ] **Image tagging strategy**
- [ ] **Automated builds**

**Status:** ⚠️ **Ready but not yet published**

**Action Required:**

1. **Manual Push:**
```bash
# Build
docker build -t kestenbroughton/traefik-cloudrun-provider:v1.0.0 .
docker build -t kestenbroughton/traefik-cloudrun-provider:latest .

# Push to Docker Hub
docker push kestenbroughton/traefik-cloudrun-provider:v1.0.0
docker push kestenbroughton/traefik-cloudrun-provider:latest
```

2. **Automated (add to .github/workflows/release.yml):**
```yaml
- name: Build and push Docker image
  uses: docker/build-push-action@v5
  with:
    push: true
    tags: |
      kestenbroughton/traefik-cloudrun-provider:${{ github.ref_name }}
      kestenbroughton/traefik-cloudrun-provider:latest
```

---

## Publication Readiness Summary

### ✅ Ready Now
- [x] Code quality tools configured
- [x] Comprehensive documentation
- [x] Unit tests (23 tests passing)
- [x] E2E tests working
- [x] CI/CD pipeline
- [x] LICENSE file
- [x] go.mod configured
- [x] Docker builds working

### ⚠️ Needs Action Before Publishing
- [ ] **Commit all changes**
- [ ] **Create GitHub repository**
- [ ] **Push to GitHub**
- [ ] **Create v1.0.0 tag**
- [ ] **Create GitHub release**
- [ ] **Add release workflow**

### ❌ Optional / Future
- [ ] Publish Docker images
- [ ] Add badges to README (after CI runs)
- [ ] Set up GitHub Pages for docs
- [ ] Restructure as Traefik plugin (v2.0)

---

## Step-by-Step Publication Process

### Step 1: Commit Current Work
```bash
git add .
git commit -m "Add quality tools, CI/CD, and comprehensive documentation

- Add pre-commit hooks with golangci-lint, gofmt, yamllint
- Add GitHub Actions CI/CD pipeline
- Add comprehensive documentation (CONTRIBUTING.md, TESTING.md, etc.)
- Add Makefile for development tasks
- Update README with clear structure
- Add E2E tests with Traefik integration"
```

### Step 2: Create GitHub Repository

1. Go to https://github.com/new
2. Repository name: `traefik-cloudrun-provider`
3. Description: "A standalone provider that dynamically discovers Google Cloud Run services and generates Traefik routing configuration"
4. Public repository
5. **DO NOT** initialize with README (we already have one)
6. Create repository

### Step 3: Push to GitHub
```bash
git remote add origin https://github.com/kestenbroughton/traefik-cloudrun-provider.git
git branch -M main
git push -u origin main
```

### Step 4: Create Release
```bash
# Create and push tag
git tag -a v1.0.0 -m "Release v1.0.0: Production-ready Cloud Run provider

Features:
- Multi-project service discovery
- Label-based routing configuration
- Identity token management with caching
- Development mode with ADC fallback
- Structured logging (text and JSON)
- Comprehensive testing (unit, Docker, E2E)
- CI/CD pipeline with quality gates"

git push origin v1.0.0
```

### Step 5: Create GitHub Release

1. Go to repository on GitHub
2. Click "Releases" → "Create a new release"
3. Choose tag: v1.0.0
4. Release title: "v1.0.0 - Initial Release"
5. Auto-generate release notes or write custom notes
6. Publish release

### Step 6: Verify Publication

**Go Package Registry:**
```bash
# Wait 5-10 minutes after pushing tag, then check:
# https://pkg.go.dev/github.com/kestenbroughton/traefik-cloudrun-provider

# Verify it's importable:
go get github.com/kestenbroughton/traefik-cloudrun-provider@v1.0.0
```

**GitHub Repository:**
- CI badge should show status
- Code should be browsable
- Issues/Discussions enabled

---

## Post-Publication

### Add Badges to README

After CI runs successfully, add badges:

```markdown
[![CI](https://github.com/kestenbroughton/traefik-cloudrun-provider/actions/workflows/ci.yml/badge.svg)](https://github.com/kestenbroughton/traefik-cloudrun-provider/actions/workflows/ci.yml)
[![Go Report Card](https://goreportcard.com/badge/github.com/kestenbroughton/traefik-cloudrun-provider)](https://goreportcard.com/report/github.com/kestenbroughton/traefik-cloudrun-provider)
[![Go Reference](https://pkg.go.dev/badge/github.com/kestenbroughton/traefik-cloudrun-provider.svg)](https://pkg.go.dev/github.com/kestenbroughton/traefik-cloudrun-provider)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
```

### Announce

- GitHub Discussions: Announce v1.0.0 release
- Update e-skimming-labs documentation to reference published package
- Consider blog post or documentation site

---

## Checklist for Publishing v1.0.0

- [ ] Commit all changes
- [ ] Create GitHub repository
- [ ] Push to GitHub
- [ ] Verify CI passes
- [ ] Create v1.0.0 tag
- [ ] Push tag
- [ ] Create GitHub release
- [ ] Verify pkg.go.dev indexing (wait 5-10 min)
- [ ] Add badges to README
- [ ] Update e-skimming-labs to reference published version
- [ ] Announce in GitHub Discussions

**Estimated Time:** 30 minutes (mostly waiting for automation)
