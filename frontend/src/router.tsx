import { createBrowserRouter, redirect } from 'react-router';

import { AppShell, RouteError } from './components/AppShell';
import { PageSpinner } from './components/ui/Spinner';
import { NotFoundPage } from './pages/NotFoundPage';
import { RecordPage } from './pages/topic/RecordPage';
import { TopicLayout, TopicTabs } from './pages/topic/TopicLayout';
import { TopicsPage } from './pages/TopicsPage';

// The list and the record screen (the hot path) ship in the main bundle;
// builder, charts and data views load on demand.
export const router = createBrowserRouter([
  {
    path: '/',
    element: <AppShell />,
    errorElement: <RouteError />,
    hydrateFallbackElement: <PageSpinner />,
    children: [
      { index: true, element: <TopicsPage /> },
      {
        path: 'settings',
        lazy: async () => ({
          Component: (await import('./pages/AppSettingsPage')).AppSettingsPage,
        }),
      },
      {
        path: 'new',
        lazy: async () => ({ Component: (await import('./pages/NewTopicPage')).NewTopicPage }),
      },
      {
        path: 't/:ref',
        element: <TopicLayout />,
        children: [
          {
            element: <TopicTabs />,
            children: [
              {
                index: true,
                lazy: async () => ({
                  Component: (await import('./pages/topic/OverviewPage')).OverviewPage,
                }),
              },
              {
                path: 'entries',
                lazy: async () => ({
                  Component: (await import('./pages/topic/EntriesPage')).EntriesPage,
                }),
              },
              {
                path: 'versions',
                lazy: async () => ({
                  Component: (await import('./pages/topic/VersionsPage')).VersionsPage,
                }),
              },
            ],
          },
          { path: 'record', element: <RecordPage /> },
          {
            // Pre-v2 URLs (bookmarks, Home Screen shortcuts): /t/:ref/sessions[/:id].
            path: 'sessions/*',
            loader: ({ params, request }) => {
              const rest = params['*'] ? `/${params['*']}` : '';
              const { search } = new URL(request.url);
              return redirect(`/t/${params.ref ?? ''}/entries${rest}${search}`);
            },
          },
          {
            path: 'entries/:entryId',
            lazy: async () => ({
              Component: (await import('./pages/topic/EntryEditPage')).EntryEditPage,
            }),
          },
          {
            path: 'edit',
            lazy: async () => ({
              Component: (await import('./pages/topic/EditQuestionsPage')).EditQuestionsPage,
            }),
          },
          {
            path: 'settings',
            lazy: async () => ({
              Component: (await import('./pages/topic/SettingsPage')).SettingsPage,
            }),
          },
        ],
      },
      { path: '*', element: <NotFoundPage /> },
    ],
  },
]);
