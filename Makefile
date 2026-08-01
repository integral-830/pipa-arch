# Vanilla Arch Linux ARM image builder for Xiaomi Pad 6 (Pipa)
#
# Usage:
#   make builder          Build the Docker builder image (once)
#   make plasma           Build the KDE Plasma desktop image
#   make gnome             Build the GNOME desktop image
#   make base              Build a console-only (no desktop) image
#   make all               Build plasma + gnome + base
#   make clean              Remove generated images

SHELL := /bin/bash
BUILDER_IMAGE := archlinux-pipa-builder
BUILDER_DIR := builder
IMAGES_DIR := images

DOCKER_RUN := docker run --rm --privileged \
	-v "$(CURDIR)/$(IMAGES_DIR):/build/images" \
	-v /dev:/dev \
	-e BUILD_GIT_REV="$(BUILD_GIT_REV)" \
	-e PIPA_PKGS_REPO_URL="$(PIPA_PKGS_REPO_URL)" \
	-e PIPA_ALARM_REPO_URL="$(PIPA_ALARM_REPO_URL)" \
	-e PIPA_INCLUDE_SENSORS="$(PIPA_INCLUDE_SENSORS)" \
	-e PIPA_INCLUDE_EXTRAS="$(PIPA_INCLUDE_EXTRAS)" \
	-e PIPA_DEFAULT_USER="$(PIPA_DEFAULT_USER)" \
	-e PIPA_DEFAULT_PASSWORD="$(PIPA_DEFAULT_PASSWORD)" \
	-e PIPA_DEFAULT_HOSTNAME="$(PIPA_DEFAULT_HOSTNAME)" \
	$(BUILDER_IMAGE)

BUILD_GIT_REV ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
PIPA_PKGS_REPO_URL ?=
PIPA_ALARM_REPO_URL ?=
PIPA_INCLUDE_SENSORS ?=
PIPA_INCLUDE_EXTRAS ?=
PIPA_DEFAULT_USER ?=
PIPA_DEFAULT_PASSWORD ?=
PIPA_DEFAULT_HOSTNAME ?=

.PHONY: help builder plasma gnome base all clean check-docker

help:
	@echo "Vanilla Arch Linux Pipa image builder"
	@echo
	@echo "Targets:"
	@echo "  builder   Build the Docker builder image"
	@echo "  plasma    Build the Plasma desktop image"
	@echo "  gnome     Build the GNOME desktop image"
	@echo "  base      Build a console-only image"
	@echo "  all       Build plasma + gnome + base"
	@echo "  clean     Remove generated images"
	@echo
	@echo "Environment variables:"
	@echo "  PIPA_PKGS_REPO_URL     Override the pipa-pkgs pacman repo URL"
	@echo "  PIPA_ALARM_REPO_URL    Override the pipa-alarm pacman repo URL"
	@echo "  PIPA_INCLUDE_SENSORS   Set to 0 to omit sensor packages (default: 1)"
	@echo "  PIPA_INCLUDE_EXTRAS    Set to 0 to skip box64/gamescope/wine/etc (default: 1)"
	@echo "  PIPA_DEFAULT_USER      Username auto-created at build time (default: pipa)"
	@echo "  PIPA_DEFAULT_PASSWORD  Password for that user + root (default: pipa)"
	@echo "  PIPA_DEFAULT_HOSTNAME  Hostname baked into the image (default: pipa)"
	@echo "  BUILD_GIT_REV          Git revision stamped into build metadata"

check-docker:
	@command -v docker >/dev/null || { echo "docker is required but not installed."; exit 1; }

builder: check-docker
	docker build --platform linux/arm64 $(BUILDER_DIR) -t $(BUILDER_IMAGE)

$(IMAGES_DIR):
	mkdir -p $(IMAGES_DIR)

plasma gnome base: builder $(IMAGES_DIR)
	$(DOCKER_RUN) $@

all: plasma gnome base

clean:
	rm -rf $(IMAGES_DIR)/*
