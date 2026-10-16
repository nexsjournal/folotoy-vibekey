# InputBetter 官网:只服务静态文件的 nginx(非 root,监听 8080)。
# 构建上下文是服务器上的 /opt/inputbetter-web(site/ + deploy/),由 deploy.sh 同步过去;DMG 已放进 site/download/。
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY deploy/nginx.conf /etc/nginx/conf.d/default.conf
COPY site /usr/share/nginx/html
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget -qO /dev/null http://127.0.0.1:8080/ || exit 1
