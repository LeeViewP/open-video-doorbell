FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
# Ring history volume: a new volume takes this directory's owner.
RUN mkdir -p /var/lib/doorbell && chown nobody /var/lib/doorbell
USER nobody
EXPOSE 8099
CMD ["python", "app.py"]
