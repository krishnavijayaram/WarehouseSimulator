# WarehouseSimulator / Flutter web — production Dockerfile
#
# The Flutter web app is built LOCALLY before docker build using:
#   puro flutter build web --release \
#     --dart-define=ENV=prod \
#     "--dart-define=GATEWAY_URL=https://wios-gateway.victoriousisland-b9d5fbf6.centralindia.azurecontainerapps.io" \
#     "--dart-define=SIM_WS_URL=wss://wios-gateway.victoriousisland-b9d5fbf6.centralindia.azurecontainerapps.io/ws/sim"
#
# Then build + push:
#   docker build -t sarathiregistry.azurecr.io/wios-flutter:latest .
#   docker push sarathiregistry.azurecr.io/wios-flutter:latest
#
# Azure for Students blocks ACR cloud builds — always build locally.

FROM nginx:1.27-alpine

# Remove the default nginx page
RUN rm -rf /usr/share/nginx/html/*

# Copy Flutter web build output
COPY build/web /usr/share/nginx/html

# nginx config: serve SPA, proxy /api and /ws to gateway (not needed in prod
# since Flutter talks to gateway directly via GATEWAY_URL dart-define).
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

CMD ["nginx", "-g", "daemon off;"]
