FROM golang:1.21-alpine AS builder

WORKDIR /app
COPY . .
RUN go mod init mock-cloudrun-service && \
    CGO_ENABLED=0 go build -o /mock-service main.go

FROM alpine:3.18
RUN apk add --no-cache ca-certificates
COPY --from=builder /mock-service /usr/local/bin/mock-service
EXPOSE 8080
CMD ["/usr/local/bin/mock-service"]
