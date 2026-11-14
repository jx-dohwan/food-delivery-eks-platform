// This MUST be the first import of main.ts, before Nest/Express/AWS/MySQL load.
import { startTracing } from './core/tracing/tracing';
startTracing();
