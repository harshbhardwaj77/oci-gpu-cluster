FROM python:3.11-slim

WORKDIR /app

# Install nvidia-smi wrapper (actual nvidia-smi comes from GPU runtime)
RUN pip install --no-cache-dir flask gunicorn psutil

COPY app.py /app/
COPY templates/ /app/templates/
COPY static/ /app/static/

EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--timeout", "120", "app:app"]
