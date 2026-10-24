import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

const DEFAULT_DISCOVERY_FILE = path.join(os.homedir(), '.ocl-mcp', 'bridge.json');

export class BridgeError extends Error {
  constructor(message, { code = 'bridge_error', cause } = {}) {
    super(message, { cause });
    this.name = 'BridgeError';
    this.code = code;
  }
}

/**
 * Client for the OpenCutList Ruby bridge.
 *
 * One persistent TCP connection, newline-delimited JSON, one request in flight
 * at a time. The discovery file is re-read whenever a new connection is
 * opened, so restarting the bridge in SketchUp does not require restarting the
 * MCP server.
 */
export class BridgeClient {
  constructor({ discoveryFile = process.env.OCL_MCP_BRIDGE_FILE || DEFAULT_DISCOVERY_FILE } = {}) {
    this.discoveryFile = discoveryFile;
    this.socket = null;
    this.buffer = '';
    this.nextId = 1;
    this.pending = new Map();
    this.chain = Promise.resolve();
  }

  /**
   * Calls one bridge command. Calls are serialized, which matches SketchUp's
   * single-threaded model and keeps cutlist state consistent.
   */
  call(method, params = {}, { timeoutMs = 30000 } = {}) {
    const run = () => this._callOnce(method, params, timeoutMs);
    const result = this.chain.then(run, run);
    this.chain = result.then(() => undefined, () => undefined);
    return result;
  }

  async _callOnce(method, params, timeoutMs) {
    const discovery = this._readDiscovery();
    const socket = await this._connect(discovery);
    const id = this.nextId++;

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new BridgeError(
          `SketchUp did not answer within ${Math.round(timeoutMs / 1000)} seconds. ` +
          'Close any open modal dialog in SketchUp, check that the MCP Bridge is still running, and call ocl_list_parts before retrying.',
          { code: 'timeout' }
        ));
      }, timeoutMs);

      this.pending.set(id, { resolve, reject, timer });

      try {
        socket.write(JSON.stringify({ id, token: discovery.token, method, params }) + '\n');
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new BridgeError('Could not send the request to SketchUp. Restart the MCP Bridge.', { code: 'bridge_write_failed', cause: error }));
      }
    });
  }

  _readDiscovery() {
    let raw;
    try {
      raw = fs.readFileSync(this.discoveryFile, 'utf8');
    } catch (error) {
      throw new BridgeError(
        `OpenCutList MCP Bridge is not running (${this.discoveryFile} not found). ` +
        'In SketchUp: Extensions → OpenCutList → MCP Bridge → Start MCP Bridge.',
        { code: 'bridge_not_running', cause: error }
      );
    }

    let data;
    try {
      data = JSON.parse(raw);
    } catch (error) {
      throw new BridgeError(`The bridge discovery file is unreadable: ${this.discoveryFile}. Restart the bridge.`, { code: 'bridge_discovery_invalid', cause: error });
    }

    if (!Number.isInteger(data.port) || typeof data.token !== 'string' || data.token.length === 0) {
      throw new BridgeError(`The bridge discovery file is incomplete: ${this.discoveryFile}. Restart the bridge.`, { code: 'bridge_discovery_invalid' });
    }

    return data;
  }

  _connect(discovery) {
    if (this.socket && !this.socket.destroyed && this.socket.bridgePort === discovery.port) {
      return Promise.resolve(this.socket);
    }

    this._destroySocket();
    this.buffer = '';

    return new Promise((resolve, reject) => {
      const socket = net.createConnection({ host: '127.0.0.1', port: discovery.port });
      socket.bridgePort = discovery.port;
      socket.setEncoding('utf8');
      socket.setNoDelay(true);

      const onError = (error) => {
        socket.removeListener('connect', onConnect);
        this._destroySocket(socket);
        reject(new BridgeError(
          'OpenCutList MCP Bridge is not reachable. Start or restart it in SketchUp: Extensions → OpenCutList → MCP Bridge → Start MCP Bridge.',
          { code: 'bridge_unreachable', cause: error }
        ));
      };

      const onConnect = () => {
        socket.removeListener('error', onError);
        socket.on('error', (error) => this._handleSocketError(socket, error));
        socket.on('close', () => this._handleSocketClose(socket));
        socket.on('data', (chunk) => this._handleData(chunk));
        this.socket = socket;
        resolve(socket);
      };

      socket.once('error', onError);
      socket.once('connect', onConnect);
    });
  }

  _handleData(chunk) {
    this.buffer += chunk;

    let index;
    while ((index = this.buffer.indexOf('\n')) !== -1) {
      const line = this.buffer.slice(0, index).trim();
      this.buffer = this.buffer.slice(index + 1);
      if (!line) {
        continue;
      }

      let message;
      try {
        message = JSON.parse(line);
      } catch {
        continue;
      }

      const pending = this.pending.get(message.id);
      if (!pending) {
        continue;
      }

      clearTimeout(pending.timer);
      this.pending.delete(message.id);

      if (message.ok) {
        pending.resolve(message.result);
      } else {
        pending.reject(new BridgeError(
          message.error?.message || 'OpenCutList returned an unknown error.',
          { code: message.error?.code || 'bridge_error' }
        ));
      }
    }
  }

  _handleSocketError(socket, error) {
    this._rejectAllPending(new BridgeError('Lost the connection to SketchUp. Restart the MCP Bridge.', { code: 'bridge_disconnected', cause: error }));
    this._destroySocket(socket);
  }

  _handleSocketClose(socket) {
    if (this.socket === socket) {
      this.socket = null;
      this.buffer = '';
    }
    this._rejectAllPending(new BridgeError('SketchUp closed the bridge connection. Restart the MCP Bridge.', { code: 'bridge_disconnected' }));
  }

  _rejectAllPending(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  _destroySocket(socket = this.socket) {
    if (!socket) {
      return;
    }
    socket.removeAllListeners();
    socket.destroy();
    if (this.socket === socket) {
      this.socket = null;
    }
  }
}
