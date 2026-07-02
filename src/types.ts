export type Track = {
  id: string;
  name: string;
  artist: string;
};

export type PlaylistResult = Track & {
  type: "playlist";
  playlist_items: Track[];
};

export type SearchResult = Track | PlaylistResult;

export type YtDlpVideoMetadata = {
  id: string;
  title: string;
  duration: number | null;
  channel: string;
};

export type YtDlpPlaylistMetadata = {
  id: string;
  title: string;
  channel: string;
  videoCount: number;
  entries: YtDlpVideoMetadata[];
};
