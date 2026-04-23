.PHONY: all
all: arm x86
.PHONY: test
test: test-arm test-x86

.PHONY: arm64
arm64:
	docker buildx build --platform=linux/arm64 -t test-native-compile-arm --no-cache --load -f Dockerfile.native .

.PHONY: x86
x86:
	docker buildx build --platform=linux/amd64 -t test-native-compile-x86 --no-cache --load -f Dockerfile.native .

test-x86: x86
	# Run the Docker container and get the file information
	$(eval arch = $(shell docker run --rm --platform=linux/amd64 test-native-compile-x86 file /out/test-native-comile | cut -d ',' -f2 | sed 's/,/ /g' | sed 's/:/ /'))
	@echo "Architecture detected: '$(arch)'"
	# TODO: check if the architecture is x86_64

test-arm64: arm64
	# Run the Docker container and get the file information
	$(eval arch = $(shell docker run --rm --platform=linux/arm64 test-native-compile-arm file /out/test-native-comile | cut -d ',' -f2 | sed 's/,/ /g' | sed 's/:/ /'))
	@echo "Architecture detected: '$(arch)'"
	# TODO: check if the architecture is arm64
