import { AuthenticatedTemplate, UnauthenticatedTemplate, useMsal } from "@azure/msal-react";
import { InteractionStatus } from "@azure/msal-browser";
import { AppShell, Button, Center, Group, Loader, Stack, Text, Title } from "@mantine/core";
import { loginRequest } from "./msalRequests.js";
import { TasksPage } from "./components/TasksPage";

export default function App() {
  const { inProgress } = useMsal();
  const clientId = import.meta.env.VITE_AZURE_AD_CLIENT_ID;

  if (!clientId) {
    return (
      <Center h="100vh" p="md">
        <Text ta="center">
          Set <code>VITE_AZURE_AD_CLIENT_ID</code> (and tenant / API scope) in <code>client/.env</code>. See{" "}
          <code>client/.env.example</code>.
        </Text>
      </Center>
    );
  }

  if (inProgress !== InteractionStatus.None) {
    return (
      <Center h="100vh">
        <Loader />
      </Center>
    );
  }

  return (
    <AppShell header={{ height: 56 }} padding="md">
      <AppShell.Header>
        <Group h="100%" px="md" justify="space-between">
          <Title order={4}>Tasks</Title>
          <AuthenticatedTemplate>
            <SignOutButton />
          </AuthenticatedTemplate>
        </Group>
      </AppShell.Header>
      <AppShell.Main>
        <UnauthenticatedTemplate>
          <Stack align="center" mt="xl" gap="md">
            <Text>Sign in with your Microsoft account to manage tasks.</Text>
            <SignInButton />
          </Stack>
        </UnauthenticatedTemplate>
        <AuthenticatedTemplate>
          <TasksPage />
        </AuthenticatedTemplate>
      </AppShell.Main>
    </AppShell>
  );
}

function SignInButton() {
  const { instance } = useMsal();
  return (
    <Button
      onClick={() => {
        void instance.loginRedirect(loginRequest);
      }}
    >
      Sign in
    </Button>
  );
}

function SignOutButton() {
  const { instance } = useMsal();
  return (
    <Button
      variant="default"
      onClick={() => {
        void instance.logoutRedirect();
      }}
    >
      Sign out
    </Button>
  );
}
