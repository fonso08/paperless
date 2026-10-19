FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl jq util-linux \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py /app/app.py
RUN useradd --uid 1000 --create-home appuser
USER appuser
EXPOSE 1889
CMD ["python", "/app/app.py"]
