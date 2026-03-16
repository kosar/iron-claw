#!/usr/bin/env node

/**
 * autoresearch.js
 * 
 * Logic for autonomous experimentation, compatible with the pi-autoresearch JSONL format.
 * Handles init, run, and log commands.
 */

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ARGS = process.argv.slice(2);
const COMMAND = ARGS[0];

// The workspace directory where we store the results
const WORKSPACE_DIR = process.cwd(); 
const JSONL_PATH = path.join(WORKSPACE_DIR, 'autoresearch.jsonl');

function log(msg) {
    console.log(`[autoresearch] ${msg}`);
}

function error(msg) {
    console.error(`[autoresearch] ERROR: ${msg}`);
    process.exit(1);
}

function parseArgs(args) {
    const params = {};
    for (let i = 0; i < args.length; i++) {
        if (args[i].startsWith('--')) {
            const key = args[i].slice(2);
            const value = args[i + 1];
            params[key] = value;
            i++;
        }
    }
    return params;
}

const PARAMS = parseArgs(ARGS.slice(1));

switch (COMMAND) {
    case 'init': {
        const { name, metric, direction } = PARAMS;
        if (!name || !metric) error('Missing --name or --metric for init');
        
        const config = {
            type: 'config',
            name,
            metricName: metric,
            bestDirection: direction || 'lower',
            timestamp: Date.now()
        };
        
        fs.appendFileSync(JSONL_PATH, JSON.stringify(config) + '\n');
        log(`Initialized experiment: ${name}`);
        break;
    }

    case 'run': {
        const { command, timeout } = PARAMS;
        if (!command) error('Missing --command for run');
        
        const t0 = Date.now();
        const result = spawnSync('bash', ['-c', command], {
            timeout: parseInt(timeout) * 1000 || 600000,
            encoding: 'utf8',
            shell: true
        });
        const duration = (Date.now() - t0) / 1000;
        
        const output = (result.stdout + '\n' + result.stderr).trim();
        const passed = result.status === 0;
        
        console.log(JSON.stringify({
            duration,
            passed,
            exitCode: result.status,
            output: output.split('\n').slice(-50).join('\n') // Last 50 lines
        }, null, 2));
        break;
    }

    case 'log': {
        const { status, metric, description, commit } = PARAMS;
        if (!status || !metric || !description) error('Missing --status, --metric, or --description for log');
        
        const entry = {
            timestamp: Date.now(),
            status,
            metric: parseFloat(metric),
            description,
            commit: commit || 'HEAD'
        };

        // Handle git automation if we are in a git repo
        if (status === 'keep') {
            log('Keeping changes, committing...');
            spawnSync('git', ['add', '-A'], { stdio: 'inherit' });
            spawnSync('git', ['commit', '-m', `[autoresearch] ${description} (metric: ${metric})`], { stdio: 'inherit' });
            // Update commit hash if possible
            const rev = spawnSync('git', ['rev-parse', '--short', 'HEAD'], { encoding: 'utf8' });
            if (rev.status === 0) entry.commit = rev.stdout.trim();
        } else if (status === 'discard' || status === 'crash') {
            log('Discarding changes, reverting...');
            // Revert all except autoresearch files
            const protectedFiles = ['autoresearch.jsonl', 'autoresearch.md', 'autoresearch.sh'];
            spawnSync('git', ['checkout', '--', '.'], { stdio: 'inherit' });
            spawnSync('git', ['clean', '-fd'], { stdio: 'inherit' });
        }

        fs.appendFileSync(JSONL_PATH, JSON.stringify(entry) + '\n');
        log(`Logged result: ${status} (${metric})`);
        break;
    }

    default:
        error('Usage: autoresearch.js <init|run|log> [params]');
}
