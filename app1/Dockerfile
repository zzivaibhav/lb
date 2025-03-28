FROM nginx:alpine
RUN echo "<html><head><title>App 1</title></head><body style='background-color: #f08080; text-align: center;'><h1>APP 1</h1><h2>This is running on $(hostname)</h2></body></html>" > /usr/share/nginx/html/index.html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
