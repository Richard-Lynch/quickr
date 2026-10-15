import { Page, TopBar } from '../components/AppShell';
import { ButtonLink } from '../components/ui/Button';
import { EmptyState } from '../components/ui/Card';

export function NotFoundPage() {
  return (
    <>
      <TopBar />
      <Page>
        <EmptyState
          title="Nothing here"
          action={
            <ButtonLink to="/" variant="primary">
              All topics
            </ButtonLink>
          }
        >
          This page does not exist (or the topic was renamed).
        </EmptyState>
      </Page>
    </>
  );
}
