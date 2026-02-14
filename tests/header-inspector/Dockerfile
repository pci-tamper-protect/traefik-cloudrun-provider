FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY . .
RUN go mod init header-inspector && \
    CGO_ENABLED=0 go build -o /header-inspector main.go

FROM alpine:3.18
RUN apk add --no-cache ca-certificates
COPY --from=builder /header-inspector /usr/local/bin/header-inspector
EXPOSE 8080
CMD ["/usr/local/bin/header-inspector"]
