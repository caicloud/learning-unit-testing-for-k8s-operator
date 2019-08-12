# learning-unit-testing-for-k8s-operator

这一 Repo 旨在帮助 Kubernetes Operators 的开发者们学习如何为 Operators 实现单元测试。其中包括：

- 为原生实现的 Operator 实现单元测试
- 为 kubebuilder v1 生成的 Operator 实现单元测试
- 为 kubebuilder v2 生成的 Operator 实现单元测试

因此这一文档的受众是 Operator 开发者们，文档中为不同的实现方式（kubebuilder v1, v2, 原生实现）设计了不同的实验，配合实验阅读味道更佳。

Table of Contents
=================

   * [learning-unit-testing-for-k8s-operator](#learning-unit-testing-for-k8s-operator)
      * [为原生实现的 Operator 实现单元测试](#为原生实现的-operator-实现单元测试)
         * [事先需要了解的知识](#事先需要了解的知识)
         * [准备工作](#准备工作)
         * [Operator 实现分析](#operator-实现分析)
            * [Operator 的初始化](#operator-的初始化)
            * [Sync 过程](#sync-过程)
            * [单元测试](#单元测试)
         * [Lab 1 实现单元测试](#lab-1-实现单元测试)
            * [问题](#问题)
            * [参考实现](#参考实现)
         * [Lab 2 扩展内容：Table Driven Test](#lab-2-扩展内容table-driven-test)
            * [背景知识](#背景知识)
            * [问题](#问题-1)
            * [参考实现](#参考实现-1)
      * [为 kubebuilder v1 生成的 Operator 实现单元测试（TODO）](#为-kubebuilder-v1-生成的-operator-实现单元测试todo)
      * [为 kubebuilder v2 生成的 Operator 实现单元测试（TODO）](#为-kubebuilder-v2-生成的-operator-实现单元测试todo)

Created by [gh-md-toc](https://github.com/ekalinin/github-markdown-toc)

## 为原生实现的 Operator 实现单元测试

原生实现的 Operator 实现单元测试的讲解与动手实验，是利用 [kubernetes/sample-controller a52d0d8](https://github.com/kubernetes/sample-controller/commit/a52d0d8c67c5addd613ec9082ed402f7f7c6579f) 作为示例展开的，为了实现动手实验的目的，修改了其单元测试 `controller_test.go` 中的内容。

### 事先需要了解的知识

- Kubernetes CRD 特性
- Kubernetes Informer 机制
- Golang 单元测试机制

### 准备工作

首先，将 `native-demo-operator` 复制到 `$GOPATH/src/k8s.io/sample-controller`。

```sh
# 将 `native-demo-operator` 复制到 `$GOPATH/src/k8s.io/sample-controller`。
./scripts/install-native-operator.sh
# 到 `$GOPATH/src/github.com/caicloud/kbv2-operator` 目录下
cd $GOPATH/src/k8s.io/sample-controller
```

这一操作是为了确保 operator 在正确的路径下。此时已经准备好了 Operator 的环境。

### Operator 实现分析

注：如果已经熟悉 [kubernetes/sample-controller](https://github.com/kubernetes/sample-controller) 的实现与自带的单元测试，可跳过这一部分。

原生实现的 Operator 实现了一个新的资源类型，Foo。Foo 的定义如下，它进一步抽象了 Deployment，只保留了 Deployment Name 和 Replicas 两个字段。在创建 Foo 时，Foo 会创建出以 Deployment Name 命名的 Deployment。而在 Foo 的状态中，只会显示目前 Foo 创建的 Deployment 目前可用的 Replicas 的数量。

```go
type Foo struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   FooSpec   `json:"spec"`
	Status FooStatus `json:"status"`
}

// FooSpec is the spec for a Foo resource
type FooSpec struct {
	DeploymentName string `json:"deploymentName"`
	Replicas       *int32 `json:"replicas"`
}

// FooStatus is the status for a Foo resource
type FooStatus struct {
	AvailableReplicas int32 `json:"availableReplicas"`
}
```

#### Operator 的初始化

如下代码是 Foo 的 Operator 初始化的过程。Foo 依赖两个 Client 和两个 Informer：kubeClient（用来操作 Deployment 资源），exampleClient（用来操作 Foo 资源），Deployment Informer（用来订阅 apiserver 上关于 Deployment 的事件），Foo Informer（用来订阅 Foo 资源的事件）。

```go
	kubeInformerFactory := kubeinformers.NewSharedInformerFactory(kubeClient, time.Second*30)
	exampleInformerFactory := informers.NewSharedInformerFactory(exampleClient, time.Second*30)

	controller := NewController(kubeClient, exampleClient,
		kubeInformerFactory.Apps().V1().Deployments(),
		exampleInformerFactory.Samplecontroller().V1alpha1().Foos())

	// notice that there is no need to run Start methods in a separate goroutine. (i.e. go kubeInformerFactory.Start(stopCh)
	// Start method is non-blocking and runs all registered informers in a dedicated goroutine.
	kubeInformerFactory.Start(stopCh)
	exampleInformerFactory.Start(stopCh)

	if err = controller.Run(2, stopCh); err != nil {
		klog.Fatalf("Error running controller: %s", err.Error())
	}
```

#### Sync 过程

Foo Operator 如同 Kubernetes 内部的 controller 一样，维护了一个 workqueue，并且利用 `syncHandler` 比对现实状态与期望状态的不同，从现实状态努力同步到期望状态。

Sync 过程如下所示，首先会得到或者创建出对应的 Deployment，然后判断 Deployment 的 Replicas 是否与 Foo 的定义一致，如果不一致，则更新 Deployment。最后，更新 Foo 的状态。

<details>
  <summary>点击此处查看 syncHandler 代码</summary>

```go
func (c *Controller) syncHandler(key string) error {
	// Convert the namespace/name string into a distinct namespace and name
	namespace, name, err := cache.SplitMetaNamespaceKey(key)
	if err != nil {
		utilruntime.HandleError(fmt.Errorf("invalid resource key: %s", key))
		return nil
	}

	// Get the Foo resource with this namespace/name
	foo, err := c.foosLister.Foos(namespace).Get(name)
	if err != nil {
		// The Foo resource may no longer exist, in which case we stop
		// processing.
		if errors.IsNotFound(err) {
			utilruntime.HandleError(fmt.Errorf("foo '%s' in work queue no longer exists", key))
			return nil
		}

		return err
	}

	deploymentName := foo.Spec.DeploymentName
	if deploymentName == "" {
		utilruntime.HandleError(fmt.Errorf("%s: deployment name must be specified", key))
		return nil
	}

	// Get the deployment with the name specified in Foo.spec
	deployment, err := c.deploymentsLister.Deployments(foo.Namespace).Get(deploymentName)
	// If the resource doesn't exist, we'll create it
	if errors.IsNotFound(err) {
		deployment, err = c.kubeclientset.AppsV1().Deployments(foo.Namespace).Create(newDeployment(foo))
	}
	if err != nil {
		return err
	}

	// If the Deployment is not controlled by this Foo resource, we should log
	// a warning to the event recorder and ret
	if !metav1.IsControlledBy(deployment, foo) {
		msg := fmt.Sprintf(MessageResourceExists, deployment.Name)
		c.recorder.Event(foo, corev1.EventTypeWarning, ErrResourceExists, msg)
		return fmt.Errorf(msg)
	}

	// If this number of the replicas on the Foo resource is specified, and the
	// number does not equal the current desired replicas on the Deployment, we
	// should update the Deployment resource.
	if foo.Spec.Replicas != nil && *foo.Spec.Replicas != *deployment.Spec.Replicas {
		klog.V(4).Infof("Foo %s replicas: %d, deployment replicas: %d", name, *foo.Spec.Replicas, *deployment.Spec.Replicas)
		deployment, err = c.kubeclientset.AppsV1().Deployments(foo.Namespace).Update(newDeployment(foo))
	}
	if err != nil {
		return err
	}
	// Finally, we update the status block of the Foo resource to reflect the
	// current state of the world
	err = c.updateFooStatus(foo, deployment)
	if err != nil {
		return err
	}
	c.recorder.Event(foo, corev1.EventTypeNormal, SuccessSynced, MessageResourceSynced)
	return nil
}
```
</details>

#### 单元测试

为了实现单元测试，Foo Operator 对其进行了抽象：

```go
type fixture struct {
	t *testing.T

	client     *fake.Clientset
	kubeclient *k8sfake.Clientset
	// Objects to put in the store.
	fooLister        []*samplecontroller.Foo
	deploymentLister []*apps.Deployment
	// Actions expected to happen on the client.
	kubeactions []core.Action
	actions     []core.Action
	// Objects from here preloaded into NewSimpleFake.
	kubeobjects []runtime.Object
	objects     []runtime.Object
}
```

fixture 在测试中，代表的就是一个在运行的 Operator，其中 `client` 与 `kubeclient` 分别是 fake 的 client。

`kubeobjects` 和 `objects` 是用来准备数据的。它们中的对象，会被添加到 `kubeclient` 和 `client` 中。这样的方式就可以完整地构建出期望的测试数据，并且通过 `kubeclient` 和 `client` 可以对测试数据进行 fake 操作。

`deploymentLister` 和 `fooLister` 会定义一系列 Deployment 和 Foo 实例，这些实例会被加入到 Informer 的 Indexer 中，以便发起 Sync 请求。

`kubeactions` 和 `actions` 是对期望状态的描述，用来记录期望观测到的，作用在 `client` 与 `kubeclient` 上的调用。

接下来，以一个 Foo Operator 的测试用例为例，介绍一下如何使用 fixture 实现单元测试用例：

```go
func TestCreatesDeployment(t *testing.T) {
	f := newFixture(t)
	foo := newFoo("test", int32Ptr(1))

	f.fooLister = append(f.fooLister, foo)
	f.objects = append(f.objects, foo)

	expDeployment := newDeployment(foo)
	f.expectCreateDeploymentAction(expDeployment)
	f.expectUpdateFooStatusAction(foo)

	f.run(getKey(foo, t))
}
```

这一测试用例用于测试创建 Deployment 的逻辑是否符合期望。首先创建出一 fixture 对象，其次构造一个用于测试的 Foo 实例。然后将 Foo 添加到 `fooLister` 和 `objects` 中。最后，构造期望的 Deployment，利用辅助函数 `expectCreateDeploymentAction` 和 `expectUpdateFooStatusAction` 将对应的期望 Action 加入到 `kubeactions` 和 `actions` 中。最后，运行 Controller 以完成整个测试。

接下来，看一下 `f.run(getKey(foo, t))` 具体的过程。

<details>
  <summary>点击此处查看 run 代码</summary>

```go
func (f *fixture) run(fooName string) {
	f.runController(fooName, true, false)
}

func (f *fixture) runController(fooName string, startInformers bool, expectError bool) {
	c, i, k8sI := f.newController()
	if startInformers {
		stopCh := make(chan struct{})
		defer close(stopCh)
		i.Start(stopCh)
		k8sI.Start(stopCh)
	}

	err := c.syncHandler(fooName)
	if !expectError && err != nil {
		f.t.Errorf("error syncing foo: %v", err)
	} else if expectError && err == nil {
		f.t.Error("expected error syncing foo, got nil")
	}

	actions := filterInformerActions(f.client.Actions())
	for i, action := range actions {
		if len(f.actions) < i+1 {
			f.t.Errorf("%d unexpected actions: %+v", len(actions)-len(f.actions), actions[i:])
			break
		}

		expectedAction := f.actions[i]
		checkAction(expectedAction, action, f.t)
	}

	if len(f.actions) > len(actions) {
		f.t.Errorf("%d additional expected actions:%+v", len(f.actions)-len(actions), f.actions[len(actions):])
	}

	k8sActions := filterInformerActions(f.kubeclient.Actions())
	for i, action := range k8sActions {
		if len(f.kubeactions) < i+1 {
			f.t.Errorf("%d unexpected actions: %+v", len(k8sActions)-len(f.kubeactions), k8sActions[i:])
			break
		}

		expectedAction := f.kubeactions[i]
		checkAction(expectedAction, action, f.t)
	}

	if len(f.kubeactions) > len(k8sActions) {
		f.t.Errorf("%d additional expected actions:%+v", len(f.kubeactions)-len(k8sActions), f.kubeactions[len(k8sActions):])
	}
}

func (f *fixture) newController() (*Controller, informers.SharedInformerFactory, kubeinformers.SharedInformerFactory) {
	f.client = fake.NewSimpleClientset(f.objects...)
	f.kubeclient = k8sfake.NewSimpleClientset(f.kubeobjects...)

	i := informers.NewSharedInformerFactory(f.client, noResyncPeriodFunc())
	k8sI := kubeinformers.NewSharedInformerFactory(f.kubeclient, noResyncPeriodFunc())

	c := NewController(f.kubeclient, f.client,
		k8sI.Apps().V1().Deployments(), i.Samplecontroller().V1alpha1().Foos())

	c.foosSynced = alwaysReady
	c.deploymentsSynced = alwaysReady
	c.recorder = &record.FakeRecorder{}

	for _, f := range f.fooLister {
		i.Samplecontroller().V1alpha1().Foos().Informer().GetIndexer().Add(f)
	}

	for _, d := range f.deploymentLister {
		k8sI.Apps().V1().Deployments().Informer().GetIndexer().Add(d)
	}

	return c, i, k8sI
}
```
</details>

run 是对另一函数 `runController(fooName string, startInformers bool, expectError bool)` 的直接调用。其中 `fooName` 就是 Foo 的 `namespace/name`，这一参数会被用来作为 `syncHandler` 的输入。第二个参数 `startInformers` 确定是否需要利用 goroutine 运行 informer 的逻辑。第三个参数 `expectError` 代表是否期望在运行中收到 error。

在 `runController` 的最开始，通过调用 `newController`，创建了 fake 的 client 和 informer，并且将数据在 client 和 informer 中准备好。接下来，是测试用例中的主要逻辑，它会把 informer 运行起来，同时去调用一次 `syncHandler`，做一次状态的比对和同步，最后检查在 client 中，是否有期望的 Action 发生。

在这一例子中，我们期望的 Action 是：

```go
    f.expectCreateDeploymentAction(expDeployment)
	f.expectUpdateFooStatusAction(foo)
```

也就是期望观测到创建 `expDeployment` 的 Action，以及更新 `Foo` 的状态的 Action。如果在测试用例运行时没有在 `runController` 时遇到这两个 Action，测试用例就会报错。

### Lab 1 实现单元测试

#### 问题

目前在代码中，已经有了四个测试用例，分别是 `TestCreatesDeployment`，`TestDoNothing`，`TestUpdateDeployment` 和 `TestNotControlledByUs`。Lab 需要完成一个新的测试用例：`TestAnonymousDeployment`。

在 `TestAnonymousDeployment` 中，用户需要测试 `Foo.Spec.DeploymentName` 为空的情况。在实现时，建议利用 `Fixture` 简化实现，具体细节可参考已有的三个测试用例。

请前往 `$GOPATH/src/k8s.io/sample-controller/controller_test.go` 实现用例 `TestAnonymousDeployment`。

#### 参考实现

在完成后，可以查看参考实现。实现方式有很多种，此处只提供其中的一种实现方式。

<details>
  <summary>点击此处查看参考实现</summary>

```go
func TestAnonymousDeployment(t *testing.T) {
	f := newFixture(t)
	foo := newFoo("test", int32Ptr(1))
	foo.Spec.DeploymentName = ""

	f.fooLister = append(f.fooLister, foo)
	f.objects = append(f.objects, foo)

	f.run(getKey(foo, t))
}
```

首先，利用 newFixture 创建了测试环境，然后创建了 `DeploymentName` 是空值的测试用例 Foo，然后将其加入到了 `fooLister` 和 `objects` 中，在 `run` 的调用中，`fooLister` 和 `objects` 中的对象会被加入到 operator 对应的 `client` 和 `informer` 中。最后，由于在 `DeploymentName` 是空值的情况下，会直接返回，不做任何处理：

```go
    if deploymentName == "" {
		// We choose to absorb the error here as the worker would requeue the
		// resource otherwise. Instead, the next time the resource is updated
		// the resource will be queued again.
		utilruntime.HandleError(fmt.Errorf("%s: deployment name must be specified", key))
		return nil
	}
```

所以，应该没有任何 Action 产生。

</details>

### Lab 2 扩展内容：Table Driven Test

#### 背景知识

在之前的实验中，所有的测试用例都是独立的，我们为了不同的情况都实现了一个 `TestXXX` 函数，这样的实现，当我们要覆盖更多 case 时，会非常冗长。这时我们可以采用 Table-Driven 的方式，把多个测试用例合并在一个用例中。举一个斐波那契数列的例子介绍这样的方式：

```go
func TestFib(t *testing.T) {
    var fibTests = []struct {
        in       int // input
        expected int // expected result
    }{
        {1, 1},
        {2, 1},
        {3, 2},
        {4, 3},
        {5, 5},
        {6, 8},
        {7, 13},
    }

    for _, tt := range fibTests {
        actual := Fib(tt.in)
        if actual != tt.expected {
            t.Errorf("Fib(%d) = %d; expected %d", tt.in, actual, tt.expected)
        }
    }
}
```

通过定义了一个测试用例的数组，在一个循环中依次进行多次测试。这样的实现可以用更少的代码覆盖更多的用例，更多介绍可以参考 [golang/go/wiki/TableDrivenTests](https://github.com/golang/go/wiki/TableDrivenTests)。

#### 问题

在这一实验中，我们需要把之前的五个测试用例，利用 Table Driven 的方法，合并成一个测试用例。

请前往 `$GOPATH/src/k8s.io/sample-controller/controller_test.go` 实现用例 `TestController`。

#### 参考实现

在完成后，可以查看参考实现。实现方式有很多种，此处只提供其中的一种实现方式。

<details>
  <summary>点击此处查看参考实现</summary>

首先，在测试函数中定义了一个结构 `TestCase`，其中包含了测试用例的名字，测试中会用到的数据 `Foo` 和 `Deployment`，控制是否将数据加入到 Controller 中的变量 `AddFooIntoController` 和 `AddDeploymentIntoController`。接下来是控制是否期望观测到对应 Action 的一系列变量 `ExpectCreateDeployment`，`ExpectUpdateDeployment` 和 `ExpectUpdateFooStatus`。最后是关于期望观测到的 Deployment 和是否期望遇到 Error 的变量 `ExpectDeployment` 和 `ExpectError`。

```go
func TestController(t *testing.T) {
	type TestCase struct {
		Case       string
		Foo        *samplecontroller.Foo
		Deployment *appsv1.Deployment

		AddFooIntoController        bool
		AddDeploymentIntoController bool

		ExpectCreateDeployment bool
		ExpectUpdateDeployment bool
		ExpectUpdateFooStatus  bool

		ExpectDeployment *appsv1.Deployment
		ExpectError      bool
	}
	testCases := []TestCase{
		{
			Case:       "TestCreatesDeployment",
			Foo:        newFoo("test", int32Ptr(1)),
			Deployment: newDeployment(newFoo("test", int32Ptr(1))),

			AddFooIntoController:        true,
			AddDeploymentIntoController: false,

			ExpectCreateDeployment: true,
			ExpectUpdateDeployment: false,
			ExpectUpdateFooStatus:  true,

			ExpectError: false,
		},
		{
			Case:       "TestDoNothing",
			Foo:        newFoo("test", int32Ptr(1)),
			Deployment: newDeployment(newFoo("test", int32Ptr(1))),

			AddFooIntoController:        true,
			AddDeploymentIntoController: true,

			ExpectCreateDeployment: false,
			ExpectUpdateDeployment: false,
			ExpectUpdateFooStatus:  true,

			ExpectError: false,
		},
		{
			Case:       "TestUpdateDeployment",
			Foo:        newFoo("test", int32Ptr(1)),
			Deployment: newDeployment(newFoo("test", int32Ptr(2))),

			AddFooIntoController:        true,
			AddDeploymentIntoController: true,

			ExpectCreateDeployment: false,
			ExpectUpdateDeployment: true,
			ExpectUpdateFooStatus:  true,

			ExpectDeployment: newDeployment(newFoo("test", int32Ptr(1))),
			ExpectError:      false,
		},
		{
			Case: "TestNotControlledByUs",
			Foo:  newFoo("test", int32Ptr(1)),
			Deployment: func() *appsv1.Deployment {
				d := newDeployment(newFoo("test", int32Ptr(2)))
				d.ObjectMeta.OwnerReferences = []metav1.OwnerReference{}
				return d
			}(),

			AddFooIntoController:        true,
			AddDeploymentIntoController: true,

			ExpectCreateDeployment: false,
			ExpectUpdateDeployment: false,
			ExpectUpdateFooStatus:  false,

			ExpectError: true,
		},
		{
			Case: "TestAnonymousDeployment",
			Foo: func() *samplecontroller.Foo {
				f := newFoo("test", int32Ptr(1))
				f.Spec.DeploymentName = ""
				return f
			}(),

			AddFooIntoController:        true,
			AddDeploymentIntoController: false,

			ExpectCreateDeployment: false,
			ExpectUpdateDeployment: false,
			ExpectUpdateFooStatus:  false,

			ExpectError: false,
		},
	}

	for _, testCase := range testCases {
		t.Logf("Running Test Case: %s", testCase.Case)
		f := newFixture(t)
		if testCase.AddFooIntoController {
			f.fooLister = append(f.fooLister, testCase.Foo)
			f.objects = append(f.objects, testCase.Foo)
		}
		if testCase.AddDeploymentIntoController {
			f.deploymentLister = append(f.deploymentLister, testCase.Deployment)
			f.kubeobjects = append(f.kubeobjects, testCase.Deployment)
		}
		if testCase.ExpectCreateDeployment {
			f.expectCreateDeploymentAction(testCase.Deployment)
		}
		if testCase.ExpectUpdateDeployment {
			if testCase.ExpectDeployment != nil {
				f.expectUpdateDeploymentAction(testCase.ExpectDeployment)
			} else {
				f.expectUpdateDeploymentAction(testCase.Deployment)
			}
		}
		if testCase.ExpectUpdateFooStatus {
			f.expectUpdateFooStatusAction(testCase.Foo)
		}
		f.runController(getKey(testCase.Foo, t), true, testCase.ExpectError)
	}
}
```

接下来，就顺理成章了。添加测试用例只需要在 `testCases` 中添加新的 `TestCase` 实例即可。

</details>

## 为 kubebuilder v1 生成的 Operator 实现单元测试（TODO）

## 为 kubebuilder v2 生成的 Operator 实现单元测试（TODO）

<!-- ### 事先需要了解的知识

TODO

### 准备工作

首先，将 `kubebuilder-v2-demo-operator` 复制到 `$GOPATH/src/github.com/caicloud/kbv2-operator`。

```sh
# 将 `kubebuilder-v2-demo-operator` 复制到 `$GOPATH/src/github.com/caicloud/kbv2-operator`。
./scripts/install-kubebuilder-v2-operator.sh
# 到 `$GOPATH/src/github.com/caicloud/kbv2-operator` 目录下
cd $GOPATH/src/github.com/caicloud/kbv2-operator
```

这一操作是为了确保 operator 在正确的路径下。此时已经准备好了 Operator 的环境。

`kubebuilder-v2-demo-operator` 目录下的代码，是由 [kubebuilder v2.0.0-beta.0](https://github.com/kubernetes-sigs/kubebuilder/releases/tag/v2.0.0-beta.0) 生成的代码，生成命令为：

注：由于代码已经生成好，所以不需要再执行上面的命令，此处的记录只是为了保证可复现。

```sh
GO111MODULE="on" kubebuilder init --domain caicloud.io --license apache2 --owner "The Operator authors"
GO111MODULE="on" kubebuilder create api --group demo --version v1 --kind Demo
```

### 基于 kubebuilder 的单元测试

TODO -->