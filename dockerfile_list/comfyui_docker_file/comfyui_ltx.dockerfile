FROM crpi-v0hudwpboba7qg38.cn-hangzhou.personal.cr.aliyuncs.com/muzihao/work:comfyui_ltx_20260629

USER root

# Install and configure OpenSSH for key-based login.
RUN apt-get update \
    && apt-get install -y --no-install-recommends openssh-server \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /root/.ssh /run/sshd \
    && chmod 700 /root/.ssh \
    && touch /root/.ssh/authorized_keys \
    && chmod 600 /root/.ssh/authorized_keys \
    && sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
    && sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

# Runtime env: empty by default; set at docker run if needed.
ENV DEFAULT_WORKFLOW=

# Startup entrypoint for sshd + ComfyUI.
COPY start.sh /start.sh
RUN chmod +x /start.sh

WORKDIR /comfyui_workspace/ComfyUI
EXPOSE 22 8888

ENTRYPOINT ["/start.sh"]
