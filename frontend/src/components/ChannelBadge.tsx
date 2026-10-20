import type { Channel } from '../client';
import { Badge } from './ui/Card';

const LABELS: Record<Channel, string> = { ui: 'Web', api: 'API', mcp: 'MCP', ios: 'iOS' };

/** Where an entry was logged from: the web app, the API, an MCP client or the iOS app. */
export function channelLabel(channel: Channel): string {
  return LABELS[channel];
}

/**
 * The channel an entry came through. The entry list shows it only for entries that didn't
 * come from this web app (`showUi` off), so iOS and API entries stand out.
 */
export function ChannelBadge({ channel, showUi = true }: { channel: Channel; showUi?: boolean }) {
  if (channel === 'ui' && !showUi) return null;
  return <Badge tone={channel === 'ios' ? 'info' : 'neutral'}>{channelLabel(channel)}</Badge>;
}
