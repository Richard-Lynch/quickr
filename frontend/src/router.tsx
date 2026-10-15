import { createBrowserRouter } from 'react-router';

import { AppShell, RouteError } from './components/AppShell';
import { NewTopicPage } from './pages/NewTopicPage';
import { NotFoundPage } from './pages/NotFoundPage';
import { EditQuestionsPage } from './pages/topic/EditQuestionsPage';
import { OverviewPage } from './pages/topic/OverviewPage';
import { RecordPage } from './pages/topic/RecordPage';
import { SessionEditPage } from './pages/topic/SessionEditPage';
import { SessionsPage } from './pages/topic/SessionsPage';
import { SettingsPage } from './pages/topic/SettingsPage';
import { TopicLayout, TopicTabs } from './pages/topic/TopicLayout';
import { VersionsPage } from './pages/topic/VersionsPage';
import { TopicsPage } from './pages/TopicsPage';

export const router = createBrowserRouter([
  {
    path: '/',
    element: <AppShell />,
    errorElement: <RouteError />,
    children: [
      { index: true, element: <TopicsPage /> },
      { path: 'new', element: <NewTopicPage /> },
      {
        path: 't/:ref',
        element: <TopicLayout />,
        children: [
          {
            element: <TopicTabs />,
            children: [
              { index: true, element: <OverviewPage /> },
              { path: 'sessions', element: <SessionsPage /> },
              { path: 'versions', element: <VersionsPage /> },
            ],
          },
          { path: 'record', element: <RecordPage /> },
          { path: 'sessions/:sessionId', element: <SessionEditPage /> },
          { path: 'edit', element: <EditQuestionsPage /> },
          { path: 'settings', element: <SettingsPage /> },
        ],
      },
      { path: '*', element: <NotFoundPage /> },
    ],
  },
]);
