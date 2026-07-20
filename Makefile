.PHONY: build clean

build:
	mkdir -p dist
	docker buildx build --platform linux/amd64 --progress=plain --output type=local,dest=dist .

clean:
	rm -rf dist

