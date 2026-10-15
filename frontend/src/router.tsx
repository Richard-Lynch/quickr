import { createBrowserRouter } from 'react-router';

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
                path: 'sessions',
                lazy: async () => ({
                  Component: (await import('./pages/topic/SessionsPage')).SessionsPage,
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
            path: 'sessions/:sessionId',
            lazy: async () => ({
              Component: (await import('./pages/topic/SessionEditPage')).SessionEditPage,
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
