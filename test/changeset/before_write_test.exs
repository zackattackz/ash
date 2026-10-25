# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Test.Changeset.BeforeWriteTest do
  @moduledoc false
  use ExUnit.Case, async: true

  require Ash.Query

  defmodule SeenAuthor do
    @moduledoc false
    # Writes `seen_author_id` from the author the write sets.
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def before_write(changeset, _opts, _context) do
      {:ok, %{seen_author_id: Ash.Changeset.get_attribute(changeset, :author_id)}}
    end
  end

  defmodule SeenTitle do
    @moduledoc false
    # Writes `seen_title` from the title the write sets, on both paths.
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def atomic(changeset, _opts, _context), do: {:ok, changeset}

    @impl true
    def before_write(changeset, _opts, _context) do
      # The title is an atomic when the action is atomic, on either path.
      case Keyword.fetch(changeset.atomics, :title) do
        {:ok, expression} -> {:ok, %{seen_title: {:atomic, expression}}}
        :error -> {:ok, %{seen_title: Ash.Changeset.get_attribute(changeset, :title)}}
      end
    end
  end

  defmodule SeenTitleRef do
    @moduledoc false
    # Reads the title being written through `atomic_ref/1`, on either path.
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def atomic(changeset, _opts, _context), do: {:ok, changeset}

    @impl true
    def before_write(_changeset, _opts, _context) do
      {:ok, %{seen_title: {:atomic, expr(^atomic_ref(:title))}}}
    end
  end

  defmodule SeenPhase do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def atomic(changeset, _opts, _context), do: {:ok, changeset}

    @impl true
    def before_write(changeset, _opts, _context),
      do: {:ok, %{seen_phase: to_string(changeset.phase)}}
  end

  defmodule AlsoSeenTitle do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def before_write(_changeset, _opts, _context), do: {:ok, %{seen_title: "also"}}
  end

  defmodule SeenAuthorAsString do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def before_write(changeset, _opts, _context) do
      {:ok, %{seen_title: inspect(Ash.Changeset.get_attribute(changeset, :seen_author_id))}}
    end
  end

  defmodule Refuse do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context), do: changeset

    @impl true
    def before_write(_changeset, _opts, _context), do: {:error, "no"}
  end

  defmodule Author do
    @moduledoc false
    use Ash.Resource,
      domain: Ash.Test.Domain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read, create: [:name]]
    end
  end

  defmodule Post do
    @moduledoc false
    use Ash.Resource,
      domain: Ash.Test.Domain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :title, :string, public?: true
      attribute :body, :string, public?: true
      attribute :seen_author_id, :uuid, public?: true
      attribute :seen_title, :string, public?: true
      attribute :seen_phase, :string, public?: true
    end

    relationships do
      belongs_to :author, Author, public?: true
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:title, :author_id]
      end

      create :create_with_author do
        accept [:title]
        argument :author_id, :uuid, allow_nil?: false
        change manage_relationship(:author_id, :author, type: :append_and_remove)
        change SeenAuthor
      end

      update :update do
        primary? true
        require_atomic? false
        accept [:title, :body]
      end

      update :move do
        require_atomic? false
        argument :author_id, :uuid, allow_nil?: false
        change manage_relationship(:author_id, :author, type: :append_and_remove)
        change SeenAuthor
      end

      update :move_in_before_transaction do
        require_atomic? false
        argument :author_id, :uuid, allow_nil?: false

        change fn changeset, _ ->
          Ash.Changeset.before_transaction(changeset, fn changeset ->
            Ash.Changeset.manage_relationship(
              changeset,
              :author,
              Ash.Changeset.get_argument(changeset, :author_id),
              type: :append_and_remove
            )
          end)
        end

        change SeenAuthor
      end

      update :seen do
        require_atomic? false
        accept [:title, :body]
        change SeenAuthor
        change SeenTitle
      end

      update :seen_atomic do
        require_atomic? true
        accept [:title]
        change SeenTitle
        change SeenPhase
      end

      update :seen_atomic_ref do
        require_atomic? true
        accept [:title]
        change SeenTitleRef
      end

      update :seen_when_b do
        require_atomic? false
        accept [:title]
        change SeenTitle, where: [attribute_equals(:title, "B")]
      end

      update :two_on_one_attribute do
        require_atomic? false
        accept [:title]
        change SeenTitle
        change AlsoSeenTitle
      end

      update :move_and_describe do
        require_atomic? false
        argument :author_id, :uuid, allow_nil?: false
        change manage_relationship(:author_id, :author, type: :append_and_remove)
        change SeenAuthor
        change SeenAuthorAsString
      end

      update :refused do
        require_atomic? false
        accept [:title]
        change Refuse
      end
    end
  end

  setup do
    %{a: Ash.create!(Author, %{name: "a"}), b: Ash.create!(Author, %{name: "b"})}
  end

  describe "sees the attribute of a managed belongs_to relationship" do
    test "on create", %{a: a} do
      post = Ash.create!(Post, %{title: "A", author_id: a.id}, action: :create_with_author)
      assert post.seen_author_id == a.id
    end

    test "in a bulk create", %{a: a} do
      assert %Ash.BulkResult{status: :success, records: [post]} =
               Ash.bulk_create([%{title: "A", author_id: a.id}], Post, :create_with_author,
                 return_records?: true,
                 return_errors?: true
               )

      assert post.seen_author_id == a.id
    end

    test "on update", %{a: a, b: b} do
      post = Ash.create!(Post, %{title: "A", author_id: a.id})
      assert Ash.update!(post, %{author_id: b.id}, action: :move).seen_author_id == b.id
    end

    test "in a bulk update", %{a: a, b: b} do
      post = Ash.create!(Post, %{title: "A", author_id: a.id})

      assert %Ash.BulkResult{status: :success, records: [post]} =
               Post
               |> Ash.Query.filter(id == ^post.id)
               |> Ash.bulk_update(:move, %{author_id: b.id},
                 strategy: :stream,
                 return_records?: true,
                 return_errors?: true
               )

      assert post.seen_author_id == b.id
    end

    test "managed in a before_transaction hook", %{a: a, b: b} do
      post = Ash.create!(Post, %{title: "A", author_id: a.id})

      assert Ash.update!(post, %{author_id: b.id}, action: :move_in_before_transaction).seen_author_id ==
               b.id
    end

    test "managed by a hook added to a built changeset", %{a: a, b: b} do
      post = Ash.create!(Post, %{title: "A", author_id: a.id})

      post =
        post
        |> Ash.Changeset.for_update(:seen, %{})
        |> Ash.Changeset.before_action(
          &Ash.Changeset.manage_relationship(&1, :author, %{id: b.id}, type: :append_and_remove)
        )
        |> Ash.update!()

      assert post.seen_author_id == b.id
    end
  end

  test "sees what hooks added to a built changeset do" do
    post = Ash.create!(Post, %{title: "A"})

    post =
      post
      |> Ash.Changeset.for_update(:seen, %{title: "B"})
      |> Ash.Changeset.before_action(&Ash.Changeset.force_change_attribute(&1, :title, "C"))
      |> Ash.update!()

    assert %{title: "C", seen_title: "C"} = post
  end

  # ETS can't run a fully atomic update, so these run with atomics on the ordinary path.
  # The atomic phase itself is covered on Postgres by the AshPaperTrail reproduction.
  describe "on the atomic path" do
    test "runs with the atomic changeset after the other atomics" do
      post = Ash.create!(Post, %{title: "A"})

      assert %{title: "B", seen_title: "B"} =
               Ash.update!(post, %{title: "B"}, action: :seen_atomic)
    end

    test "in a bulk atomic update, in the atomic phase" do
      post = Ash.create!(Post, %{title: "A"})

      assert %Ash.BulkResult{status: :success, records: [updated]} =
               Post
               |> Ash.Query.filter(id == ^post.id)
               |> Ash.bulk_update(:seen_atomic, %{title: "B"},
                 strategy: :atomic,
                 return_records?: true,
                 return_errors?: true
               )

      assert %{title: "B", seen_title: "B", seen_phase: "atomic"} = updated
    end

    test "atomic_ref/1 resolves to the value being written, on either path" do
      post = Ash.create!(Post, %{title: "A"})

      assert %{title: "B", seen_title: "B"} =
               Ash.update!(post, %{title: "B"}, action: :seen_atomic_ref)

      assert %Ash.BulkResult{status: :success, records: [updated]} =
               Post
               |> Ash.Query.filter(id == ^post.id)
               |> Ash.bulk_update(:seen_atomic_ref, %{title: "C"},
                 strategy: :atomic,
                 return_records?: true,
                 return_errors?: true
               )

      assert %{title: "C", seen_title: "C"} = updated
    end
  end

  test "a change's where: conditions are evaluated against the changeset as written" do
    post = Ash.create!(Post, %{title: "A"})

    assert %{seen_title: "B"} = Ash.update!(post, %{title: "B"}, action: :seen_when_b)
    assert %{seen_title: "B"} = Ash.update!(post, %{title: "C"}, action: :seen_when_b)
  end

  test "callbacks don't see each other's values, and all apply", %{a: a, b: b} do
    post = Ash.create!(Post, %{title: "A", author_id: a.id})
    post = Ash.update!(post, %{author_id: b.id}, action: :move_and_describe)

    assert post.seen_author_id == b.id
    assert post.seen_title == "nil"
  end

  test "two callbacks returning the same attribute is an error" do
    post = Ash.create!(Post, %{title: "A"})

    assert {:error, error} = Ash.update(post, %{title: "B"}, action: :two_on_one_attribute)
    assert Exception.message(error) =~ "more than one before_write/3"
    assert %{title: "A"} = Ash.get!(Post, post.id)
  end

  test "values alone don't write an update" do
    post = Ash.create!(Post, %{title: "A"})
    Ash.update!(post, %{}, action: :seen)

    assert %{seen_title: nil} = Ash.get!(Post, post.id)
  end

  test "changed? in the context writes the update, and the values with it" do
    post = Ash.create!(Post, %{title: "A"})

    post
    |> Ash.Changeset.for_update(:seen, %{})
    |> Ash.Changeset.set_context(%{changed?: true})
    |> Ash.update!()

    assert %{seen_title: "A"} = Ash.get!(Post, post.id)
  end

  test "changed? in the context writes a bulk stream update too" do
    post = Ash.create!(Post, %{title: "A"})

    assert %Ash.BulkResult{status: :success} =
             Ash.bulk_update([post], :seen, %{},
               strategy: :stream,
               context: %{changed?: true},
               return_errors?: true
             )

    assert %{seen_title: "A"} = Ash.get!(Post, post.id)
  end

  test "an error from a callback stops the write" do
    post = Ash.create!(Post, %{title: "A"})

    assert {:error, _} = Ash.update(post, %{title: "B"}, action: :refused)
    assert %{title: "A"} = Ash.get!(Post, post.id)
  end
end
